#!/bin/bash
# CC×Codex 自律開発ループ ラッパー (supervisor mode)
# 使い方: ~/.claude/scripts/auto-loop.sh [project-dir]
#
# 目的:
# - /auto が不意に終了しても、作業未完了なら自動再開する
# - ただし無限ループを防ぐため、再開回数と無進捗回数に上限を設ける

set -uo pipefail

PROJECT_DIR="${1:-$(pwd)}"
RESUME_FILE="$PROJECT_DIR/.claude/auto-resume.md"
DONE_FILE="$PROJECT_DIR/.claude/auto-done"
GOAL_FILE="$PROJECT_DIR/.claude/prompts/goal.md"
PLAN_FILE="$PROJECT_DIR/.claude/plan.md"
LAST_OUTPUT_FILE="$PROJECT_DIR/.claude/auto-last-output.log"
RATE_LIMIT_WAIT_FILE="$PROJECT_DIR/.claude/auto-rate-limit-wait.json"

CLAUDE_CMD="${AUTO_LOOP_CLAUDE_CMD:-claude}"

MAX_RESTARTS="${AUTO_LOOP_MAX_RESTARTS:-10}"
NO_PROGRESS_LIMIT="${AUTO_LOOP_NO_PROGRESS_LIMIT:-4}"
BASE_BACKOFF_SEC="${AUTO_LOOP_BASE_BACKOFF_SEC:-3}"
MAX_BACKOFF_SEC="${AUTO_LOOP_MAX_BACKOFF_SEC:-60}"
FATAL_ERROR_REGEX="${AUTO_LOOP_FATAL_ERROR_REGEX:-(goal\.md not found|[Pp]ermission denied|Operation not permitted|ModuleNotFoundError|ImportError|SyntaxError|Traceback \(most recent call last\)|command not found)}"

forced_restarts=0
no_progress_count=0

is_non_negative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

clamp_numeric_config() {
  if ! is_non_negative_int "$MAX_RESTARTS"; then MAX_RESTARTS=10; fi
  if ! is_non_negative_int "$NO_PROGRESS_LIMIT"; then NO_PROGRESS_LIMIT=4; fi
  if ! is_non_negative_int "$BASE_BACKOFF_SEC"; then BASE_BACKOFF_SEC=3; fi
  if ! is_non_negative_int "$MAX_BACKOFF_SEC"; then MAX_BACKOFF_SEC=60; fi
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
    return 0
  fi
  # Status tokens: [ ] [>] [!]
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

  # Fallback: if all tasks are [x], treat as complete
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

  # Explicit done marker always wins
  if [[ -f "$DONE_FILE" ]]; then
    return 1
  fi

  # Non-zero exit is treated as recoverable by default (fatal path handled separately)
  if [[ "$exit_code" -ne 0 ]]; then
    return 0
  fi

  # Exit 0 but still incomplete -> force restart
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
}

compute_backoff() {
  local attempt="$1"
  local delay="$BASE_BACKOFF_SEC"

  # Exponential backoff with cap
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

  if (( wait_sec > 0 )); then
    local reset_local
    reset_local=$(date -d "$resets_at" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$resets_at")
    echo "--- Rate limit hit. Waiting until $reset_local (${wait_sec}s) ---"
    sleep "$wait_sec"
    # Add a small buffer after reset
    sleep 10
  else
    echo "--- Rate limit reset time already passed. Continuing. ---"
  fi

  rm -f "$RATE_LIMIT_WAIT_FILE"
  return 0
}

clamp_numeric_config
ensure_preconditions

echo "=== CC×Codex Auto Loop (Supervisor) ==="
echo "Project: $PROJECT_DIR"
echo "Policy: restart on incomplete work; stop on completion/fatal"
echo "Limits: max_restarts=$MAX_RESTARTS, no_progress_limit=$NO_PROGRESS_LIMIT"
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

  if [[ -f "$RESUME_FILE" ]]; then
    echo "--- Resuming from handoff ---"
    PROMPT="$(cat "$RESUME_FILE")"
    rm -f "$RESUME_FILE"
    cd "$PROJECT_DIR" && $CLAUDE_CMD "$PROMPT" 2>&1 | tee "$LAST_OUTPUT_FILE"
    EXIT_CODE=${PIPESTATUS[0]}
  else
    echo "--- Starting /auto ---"
    cd "$PROJECT_DIR" && $CLAUDE_CMD "/auto" 2>&1 | tee "$LAST_OUTPUT_FILE"
    EXIT_CODE=${PIPESTATUS[0]}
  fi

  # If auto created resume, continue immediately with a short delay.
  if [[ -f "$RESUME_FILE" ]]; then
    no_progress_count=0
    echo ""
    echo "--- Session ended with resume file. Restarting in 3s... ---"
    sleep 3
    continue
  fi

  if is_fatal_failure "$EXIT_CODE"; then
    echo "=== Loop stopped: fatal error detected ==="
    echo "Last exit code: $EXIT_CODE"
    echo "Matched fatal regex: $FATAL_ERROR_REGEX"
    echo "Recent /auto output:"
    tail -n 40 "$LAST_OUTPUT_FILE"
    exit "$EXIT_CODE"
  fi

  after_hash="$(plan_hash)"
  if [[ "$before_hash" == "$after_hash" ]]; then
    no_progress_count=$((no_progress_count + 1))
  else
    no_progress_count=0
  fi

  if should_force_restart "$EXIT_CODE"; then
    forced_restarts=$((forced_restarts + 1))

    if (( forced_restarts > MAX_RESTARTS )); then
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

  if [[ -f "$DONE_FILE" ]]; then
    echo "=== Loop finished (done marker detected) ==="
  elif plan_is_complete; then
    echo "=== Loop finished (plan complete) ==="
  else
    echo "=== Loop finished (no resume and no restart condition) ==="
  fi
  exit "$EXIT_CODE"
done
