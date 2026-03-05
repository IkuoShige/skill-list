#!/bin/bash
# CC×Codex 自律開発ループ ラッパー (supervisor mode, tmux)
# 使い方: ~/.claude/scripts/auto-loop.sh [project-dir] [auto-args...]
#
# 目的:
# - /auto スキルを対話モードで tmux 内に起動し、自律開発を回す
# - handoff (auto-resume.md) や完了 (auto-done) を検知して自動ループ
# - ユーザーは tmux attach で介入可能
# - 無限ループ防止: 再開回数・無進捗回数に上限

set -uo pipefail

PROJECT_DIR="${1:-$(pwd)}"
shift 2>/dev/null || true
AUTO_ARGS="$*"

RESUME_FILE="$PROJECT_DIR/.claude/auto-resume.md"
DONE_FILE="$PROJECT_DIR/.claude/auto-done"
GOAL_FILE="$PROJECT_DIR/.claude/prompts/goal.md"
PLAN_FILE="$PROJECT_DIR/.claude/plan.md"
LAST_OUTPUT_FILE="$PROJECT_DIR/.claude/auto-last-output.log"
RATE_LIMIT_WAIT_FILE="$PROJECT_DIR/.claude/auto-rate-limit-wait.json"

CLAUDE_CMD="${AUTO_LOOP_CLAUDE_CMD:-claude}"
CLAUDE_ARGS="${AUTO_LOOP_CLAUDE_ARGS:---verbose}"
AUTO_SKILL_FILE="${AUTO_LOOP_SKILL_FILE:-$HOME/.claude/commands/auto.md}"

MAX_RESTARTS="${AUTO_LOOP_MAX_RESTARTS:-10}"
NO_PROGRESS_LIMIT="${AUTO_LOOP_NO_PROGRESS_LIMIT:-4}"
BASE_BACKOFF_SEC="${AUTO_LOOP_BASE_BACKOFF_SEC:-3}"
MAX_BACKOFF_SEC="${AUTO_LOOP_MAX_BACKOFF_SEC:-60}"
MAX_RATE_LIMIT_WAIT="${AUTO_LOOP_MAX_RATE_LIMIT_WAIT:-1800}"
POLL_INTERVAL_SEC="${AUTO_LOOP_POLL_INTERVAL_SEC:-5}"
IDLE_TIMEOUT_SEC="${AUTO_LOOP_IDLE_TIMEOUT_SEC:-300}"
FATAL_ERROR_REGEX="${AUTO_LOOP_FATAL_ERROR_REGEX:-(goal\.md not found|[Pp]ermission denied|Operation not permitted|ModuleNotFoundError|ImportError|SyntaxError|Traceback \(most recent call last\)|command not found)}"

TMUX_SESSION_NAME="auto-loop-$(basename "$PROJECT_DIR")"

forced_restarts=0
no_progress_count=0

# --- Signal handling ---
cleanup() {
  echo ""
  echo "[auto-loop] Cleaning up..."
  tmux kill-session -t "$TMUX_SESSION_NAME" 2>/dev/null || true
  stty sane 2>/dev/null || true
  echo "[auto-loop] Cleaned up."
}
trap cleanup EXIT INT TERM

# --- Utility functions ---

is_non_negative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

clamp_numeric_config() {
  if ! is_non_negative_int "$MAX_RESTARTS"; then MAX_RESTARTS=10; fi
  if ! is_non_negative_int "$NO_PROGRESS_LIMIT"; then NO_PROGRESS_LIMIT=4; fi
  if ! is_non_negative_int "$BASE_BACKOFF_SEC"; then BASE_BACKOFF_SEC=3; fi
  if ! is_non_negative_int "$MAX_BACKOFF_SEC"; then MAX_BACKOFF_SEC=60; fi
  if ! is_non_negative_int "$MAX_RATE_LIMIT_WAIT"; then MAX_RATE_LIMIT_WAIT=1800; fi
  if ! is_non_negative_int "$POLL_INTERVAL_SEC"; then POLL_INTERVAL_SEC=5; fi
  if ! is_non_negative_int "$IDLE_TIMEOUT_SEC"; then IDLE_TIMEOUT_SEC=300; fi
  if (( MAX_BACKOFF_SEC < BASE_BACKOFF_SEC )); then
    MAX_BACKOFF_SEC="$BASE_BACKOFF_SEC"
  fi
}

plan_hash() {
  if [[ -f "$PLAN_FILE" ]]; then
    sha256sum "$PLAN_FILE" | awk '{print $1}'
  else
    echo "__MISSING_PLAN__"
  fi
}

plan_has_incomplete_tasks() {
  if [[ ! -f "$PLAN_FILE" ]]; then
    return 1
  fi
  grep -Eq '^### Task .*\[( |>|!)\]' "$PLAN_FILE"
}

plan_is_complete() {
  if [[ ! -f "$PLAN_FILE" ]]; then
    return 1
  fi

  if grep -Eq '^Status:[[:space:]]*COMPLETE(D)?[[:space:]]*$' "$PLAN_FILE"; then
    if plan_has_incomplete_tasks; then
      return 1
    fi
    return 0
  fi

  if grep -Eq '^### Task ' "$PLAN_FILE"; then
    if plan_has_incomplete_tasks; then
      return 1
    fi
    return 0
  fi

  return 1
}

should_force_restart() {
  local exit_code="$1"

  if [[ -f "$DONE_FILE" ]]; then
    return 1
  fi

  if [[ "$exit_code" -ne 0 ]]; then
    return 0
  fi

  if ! plan_is_complete; then
    return 0
  fi

  return 1
}

is_fatal_failure() {
  local exit_code="$1"

  if [[ "$exit_code" -eq 0 ]]; then
    return 1
  fi
  if [[ ! -f "$LAST_OUTPUT_FILE" ]]; then
    return 1
  fi

  grep -Eiq "$FATAL_ERROR_REGEX" "$LAST_OUTPUT_FILE"
}

ensure_preconditions() {
  if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "[FATAL] Project directory not found: $PROJECT_DIR"
    exit 2
  fi

  mkdir -p "$PROJECT_DIR/.claude"

  if [[ ! -f "$GOAL_FILE" ]]; then
    echo "[FATAL] goal.md not found: $GOAL_FILE"
    echo "Create goal.md first, then rerun auto-loop.sh"
    exit 2
  fi

  if [[ ! -f "$AUTO_SKILL_FILE" ]]; then
    echo "[FATAL] auto skill file not found: $AUTO_SKILL_FILE"
    exit 2
  fi
}

ensure_tmux() {
  if ! command -v tmux &>/dev/null; then
    echo "[FATAL] tmux is not installed."
    exit 2
  fi
}

compute_backoff() {
  local attempt="$1"
  local delay="$BASE_BACKOFF_SEC"

  if (( attempt > 1 )); then
    local pow=$((attempt - 1))
    delay=$(( BASE_BACKOFF_SEC * (2 ** pow) ))
  fi

  if (( delay > MAX_BACKOFF_SEC )); then
    delay="$MAX_BACKOFF_SEC"
  fi

  echo "$delay"
}

wait_for_rate_limit_reset() {
  if [[ ! -f "$RATE_LIMIT_WAIT_FILE" ]]; then
    return 0
  fi

  local resets_at
  resets_at=$(grep -o '"resetsAt"[[:space:]]*:[[:space:]]*"[^"]*"' "$RATE_LIMIT_WAIT_FILE" | head -1 | sed 's/.*"resetsAt"[[:space:]]*:[[:space:]]*"//;s/"//')

  if [[ -z "$resets_at" ]]; then
    echo "[Warn] Rate limit wait file found but no resetsAt. Removing and continuing."
    rm -f "$RATE_LIMIT_WAIT_FILE"
    return 0
  fi

  local reset_epoch now_epoch wait_sec
  reset_epoch=$(date -d "$resets_at" +%s 2>/dev/null)
  if [[ -z "$reset_epoch" ]]; then
    echo "[Warn] Could not parse resetsAt: $resets_at. Removing and continuing."
    rm -f "$RATE_LIMIT_WAIT_FILE"
    return 0
  fi

  now_epoch=$(date +%s)
  wait_sec=$(( reset_epoch - now_epoch ))

  if (( wait_sec > MAX_RATE_LIMIT_WAIT )); then
    echo "[Warn] Rate limit wait ${wait_sec}s exceeds cap ${MAX_RATE_LIMIT_WAIT}s. Clamping."
    wait_sec="$MAX_RATE_LIMIT_WAIT"
  fi

  if (( wait_sec > 0 )); then
    local reset_local
    reset_local=$(date -d "$resets_at" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$resets_at")
    echo "--- Rate limit hit. Waiting until $reset_local (${wait_sec}s) ---"
    sleep "$wait_sec"
    sleep 10
  else
    echo "--- Rate limit reset time already passed. Continuing. ---"
  fi

  rm -f "$RATE_LIMIT_WAIT_FILE"
  return 0
}

# --- tmux functions ---

kill_existing_session() {
  if tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
    echo "[Info] Killing existing tmux session: $TMUX_SESSION_NAME"
    tmux kill-session -t "$TMUX_SESSION_NAME"
  fi
}

start_claude_in_tmux() {
  local prompt="$1"

  kill_existing_session

  # Truncate log for this iteration
  : > "$LAST_OUTPUT_FILE"

  # Create detached tmux session
  tmux new-session -d -s "$TMUX_SESSION_NAME" -x 220 -y 50

  # Capture output to log file (output only, append)
  tmux pipe-pane -t "$TMUX_SESSION_NAME" -o "cat >> '${LAST_OUTPUT_FILE}'"

  # Unset Claude nesting guard, then launch claude.
  # After claude exits, 'exit' closes the shell and thus the tmux pane.
  # This makes is_pane_alive() return false, which is our exit signal.
  tmux send-keys -t "$TMUX_SESSION_NAME" \
    "unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ACCESS_TOKEN && cd $(printf '%q' "$PROJECT_DIR") && $(printf '%q' "$CLAUDE_CMD") $(printf '%q' "$prompt") $CLAUDE_ARGS; exit" \
    Enter

  # Auto-approve workspace trust dialog (appears on first access to a directory)
  # Poll the log until trust dialog or normal prompt appears, then send Enter
  local trust_wait=0
  while (( trust_wait < 15 )); do
    sleep 1
    trust_wait=$((trust_wait + 1))
    if [[ -f "$LAST_OUTPUT_FILE" ]]; then
      # Trust dialog detected — send Enter to approve
      if grep -q "trust this folder" "$LAST_OUTPUT_FILE" 2>/dev/null; then
        echo "[Info] Trust dialog detected, auto-approving..."
        tmux send-keys -t "$TMUX_SESSION_NAME" Enter
        break
      fi
      # Normal prompt appeared (no trust dialog needed)
      if grep -q "tokens" "$LAST_OUTPUT_FILE" 2>/dev/null; then
        break
      fi
    fi
  done

  echo "[Info] tmux session started: $TMUX_SESSION_NAME"
  echo "[Info] Attach with: tmux attach -t $TMUX_SESSION_NAME"
}

is_pane_alive() {
  tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null
}

claude_has_exited() {
  # When claude exits, the shell runs 'exit' too, closing the pane.
  # So pane not alive = claude exited.
  ! is_pane_alive
}

capture_output() {
  if is_pane_alive; then
    tmux capture-pane -t "$TMUX_SESSION_NAME" -p -S - >> "$LAST_OUTPUT_FILE" 2>/dev/null || true
  fi
}

send_exit_to_pane() {
  if ! is_pane_alive; then
    return 0
  fi

  echo "[Info] Sending /exit to claude session..."
  tmux send-keys -t "$TMUX_SESSION_NAME" "/exit" Enter

  local wait_count=0
  while (( wait_count < 15 )); do
    sleep 1
    wait_count=$((wait_count + 1))
    if claude_has_exited; then
      echo "[Info] Claude exited gracefully."
      return 0
    fi
  done

  echo "[Warn] Claude did not exit in time. Killing session."
  tmux kill-session -t "$TMUX_SESSION_NAME" 2>/dev/null || true
}

# Wait for session to end by polling signal files and pane status.
# Returns: 0 = signal file detected, 1 = claude exited without signal, 2 = idle timeout
wait_for_session_end() {
  local last_output_size=0
  local idle_start=""

  while true; do
    sleep "$POLL_INTERVAL_SEC"

    # Priority 1: Check signal files
    if [[ -f "$DONE_FILE" ]]; then
      echo "[Info] Done marker detected."
      capture_output
      send_exit_to_pane
      return 0
    fi

    if [[ -f "$RESUME_FILE" ]]; then
      echo "[Info] Resume file detected (handoff)."
      capture_output
      send_exit_to_pane
      return 0
    fi

    # Priority 2: Check if claude has exited
    if claude_has_exited; then
      echo "[Info] Claude process exited."
      capture_output
      tmux kill-session -t "$TMUX_SESSION_NAME" 2>/dev/null || true
      return 1
    fi

    # Priority 3: Check for idle timeout
    local current_size=0
    if [[ -f "$LAST_OUTPUT_FILE" ]]; then
      current_size=$(stat -c %s "$LAST_OUTPUT_FILE" 2>/dev/null || echo 0)
    fi

    if (( current_size != last_output_size )); then
      last_output_size=$current_size
      idle_start=""
    else
      if [[ -z "$idle_start" ]]; then
        idle_start=$(date +%s)
      else
        local now idle_duration
        now=$(date +%s)
        idle_duration=$(( now - idle_start ))
        if (( idle_duration >= IDLE_TIMEOUT_SEC )); then
          echo "[Warn] Idle timeout (${IDLE_TIMEOUT_SEC}s) reached. Claude may be waiting for input."
          capture_output
          send_exit_to_pane
          return 2
        fi
      fi
    fi

    # Priority 4: Rate limit file (reset idle timer, don't interrupt)
    if [[ -f "$RATE_LIMIT_WAIT_FILE" ]]; then
      idle_start=""
    fi
  done
}

# === Main ===

clamp_numeric_config
ensure_tmux
ensure_preconditions

echo "=== CC×Codex Auto Loop (Supervisor, tmux mode) ==="
echo "Project: $PROJECT_DIR"
echo "tmux session: $TMUX_SESSION_NAME"
echo "Auto args: ${AUTO_ARGS:-<none>}"
echo "Policy: restart on incomplete work; stop on completion/fatal"
echo "Limits: max_restarts=$MAX_RESTARTS, no_progress_limit=$NO_PROGRESS_LIMIT"
echo "Idle timeout: ${IDLE_TIMEOUT_SEC}s"
echo "Attach: tmux attach -t $TMUX_SESSION_NAME"
echo "Ctrl+C to stop"
echo ""

# Stale marker from an old run can block startup; remove if plan is not complete.
if [[ -f "$DONE_FILE" ]] && ! plan_is_complete; then
  echo "[Info] Removing stale done marker: $DONE_FILE"
  rm -f "$DONE_FILE"
fi

while true; do
  ensure_preconditions

  # Wait for rate limit reset if needed (written by CC's budget policy)
  wait_for_rate_limit_reset

  before_hash="$(plan_hash)"

  # Determine prompt
  if [[ -f "$RESUME_FILE" ]]; then
    echo "--- Resuming from handoff ---"
    PROMPT="$(cat "$RESUME_FILE")"
    rm -f "$RESUME_FILE"
  else
    echo "--- Starting /auto ---"
    PROMPT="/auto${AUTO_ARGS:+ $AUTO_ARGS}"
  fi

  # Launch claude in tmux (interactive mode, full skill support)
  start_claude_in_tmux "$PROMPT"

  # Wait for session to end (polling signal files + pane status)
  wait_for_session_end
  WAIT_RESULT=$?

  # Handle resume file (handoff) — continue immediately
  if [[ -f "$RESUME_FILE" ]]; then
    no_progress_count=0
    echo ""
    echo "--- Session ended with resume file. Restarting in 3s... ---"
    sleep 3
    continue
  fi

  # Synthesize EXIT_CODE from signal files + wait result
  if [[ -f "$DONE_FILE" ]]; then
    EXIT_CODE=0
  elif (( WAIT_RESULT == 0 )); then
    EXIT_CODE=0
  else
    EXIT_CODE=1
  fi

  # Fatal error check
  if is_fatal_failure "$EXIT_CODE"; then
    echo "=== Loop stopped: fatal error detected ==="
    echo "Matched fatal regex: $FATAL_ERROR_REGEX"
    echo "Recent /auto output:"
    tail -n 40 "$LAST_OUTPUT_FILE"
    exit "$EXIT_CODE"
  fi

  # Progress tracking
  after_hash="$(plan_hash)"
  if [[ "$before_hash" == "$after_hash" ]]; then
    no_progress_count=$((no_progress_count + 1))
  else
    no_progress_count=0
  fi

  # Force restart logic
  if should_force_restart "$EXIT_CODE"; then
    forced_restarts=$((forced_restarts + 1))

    if (( forced_restarts >= MAX_RESTARTS )); then
      echo "=== Loop stopped: forced-restart limit reached ($MAX_RESTARTS) ==="
      echo "Last exit code: $EXIT_CODE"
      exit "$EXIT_CODE"
    fi

    if (( no_progress_count >= NO_PROGRESS_LIMIT )); then
      echo "=== Loop stopped: no progress detected for $NO_PROGRESS_LIMIT cycles ==="
      echo "Last exit code: $EXIT_CODE"
      echo "Tip: inspect .claude/plan.md and the latest /auto output"
      exit "$EXIT_CODE"
    fi

    backoff="$(compute_backoff "$forced_restarts")"
    echo "--- /auto ended but work is incomplete. Force restarting in ${backoff}s (attempt ${forced_restarts}/${MAX_RESTARTS}) ---"
    sleep "$backoff"
    continue
  fi

  # Clean exit
  if [[ -f "$DONE_FILE" ]]; then
    echo "=== Loop finished (done marker detected) ==="
  elif plan_is_complete; then
    echo "=== Loop finished (plan complete) ==="
  else
    echo "=== Loop finished (no resume and no restart condition) ==="
  fi
  exit "${EXIT_CODE:-0}"
done
