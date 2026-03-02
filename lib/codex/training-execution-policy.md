# Training Execution Policy

## 適用条件
以下のいずれかを満たす場合、このプロトコルを適用する:
- `plan.md` に `[Train]` タスクがある
- `goal.md` に `## Training Configuration` セクションがある

## プロトコル概要

```
Pre-Launch → Launch → Monitor → Post-Training
  (GPU/VRAM)   (background)  (polling loop)  (結果収集)
```

---

## Section 1: Pre-Launch Protocol

### GPU可用性チェック

1. compute プロセス確認:
```bash
nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits
```
2. PID allowlist方式: 起動前はallowlist空。compute PIDが1つでもあれば「他者使用中」と判定
3. 補助チェック（他者判別）:
   - `/proc/{pid}/cgroup` でコンテナ確認
   - `/proc/{pid}/cmdline` で `HOLO_RUN_ID` の有無を確認
   - `/proc/{pid}/status` の UID で自分のプロセスか判別
4. 非GPU系プロセス（Xorg, gnome-shell等）は除外
5. 他者使用中の場合:
   - `[Training] GPU busy — 他ユーザーが使用中。60秒後に再チェックします` と通知
   - 60秒間隔でポーリング、最大30分
   - 30分超過: ユーザーに報告して一時停止（auto-handoffしない）
   - `[Training] GPU待機タイムアウト（30分）。ユーザー判断を待ちます` と通知

### VRAM予算計算

1. 空きVRAM取得:
```bash
nvidia-smi --query-gpu=memory.free,memory.total --format=csv,noheader,nounits
```
2. 最大環境数を計算:
```
max_envs = floor((free_vram - vram_overhead_mb) / vram_per_env_mb)
```
パラメータは `goal.md` の `## Training Configuration` → `### VRAM Budget` から取得

3. 判定:

| 条件 | アクション |
|------|----------|
| `max_envs >= requested` | そのまま起動 |
| `max_envs >= min_num_envs` | 削減して警告: `[Training] VRAM不足: num_envs={requested}→{max_envs}に削減` |
| `max_envs < min_num_envs` | GPU待機ループに入る（他者使用中と同じフロー） |

---

## Section 2: Launch Protocol

### 手順

1. **ログディレクトリ作成:**
```bash
mkdir -p {project}/.claude/logs
```

2. **Run ID生成:**
```
HOLO_RUN_ID=auto_{timestamp}_{pid}
```
timestamp形式: `%Y%m%d_%H%M%S`

3. **コマンド構築:**
```bash
HOLO_RUN_ID={id} conda run -n {conda_env} --no-banner {base_command} exp:{preset} {num_envs_arg} simulator:{simulator} {extra_args} > {logfile} 2>&1
```
パラメータは `goal.md` の `## Training Configuration` から取得:
- `conda_env`, `simulator`, `base_command`, `preset`, `extra_args`, `num_envs_arg_template`
- `base_command` には実行バイナリを含める（例: `python train_agent.py`）
- `N` は Pre-Launch で決定した環境数
- `num_envs_arg = num_envs_arg_template` の `{N}` 展開結果を使う（未指定時は `--training.num-envs={N}` をデフォルト）

4. **バックグラウンド起動:**
`Bash(run_in_background=true)` で実行

5. **PID取得とallowlist登録:**
起動後に `nvidia-smi --query-compute-apps=pid --format=csv,noheader` でPIDを取得し、allowlistに追加

6. **通知:**
```
[Training] Started: {preset} | num_envs={N} | run_id={id}
```

---

## Section 3: Monitoring Loop

CCの制御フローで駆動するポーリングパターン。shell-levelのループではない。

### 各イテレーション

**ステップ1: 状態取得（1回のBash呼び出しに統合）**
```bash
PID_ALIVE=$(kill -0 {pid} 2>/dev/null && echo "alive" || echo "dead")
LOG_TAIL=$(tail -n 100 "{logfile}")
GPU_STATE=$(nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,memory.used --format=csv,noheader,nounits)
GPU_PIDS=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader)
echo "PID_STATUS:$PID_ALIVE"; echo "---LOG---"; echo "$LOG_TAIL"
echo "---GPU---"; echo "$GPU_STATE"; echo "---PIDS---"; echo "$GPU_PIDS"
```

**ステップ2: 待機**
別のBash呼び出しで `sleep {monitoring_interval}`（goal.mdのmonitoring_interval秒）

**ステップ3: 次イテレーションへ**

### メトリクス解析

stdoutからパターンマッチでメトリクスを抽出する:
- **reward**: `goal.md` の `reward_pattern` で抽出
- **loss**: `goal.md` の `loss_pattern` で抽出
- **iteration (primary)**: `goal.md` の `iter_pattern` で抽出
- **iteration (fallback)**: primaryが取れない場合は `iter_fallback_pattern`（例: `model_(\d{5})\.pt`）で推定
- **NaN検出**: `NaN` または `nan` の出現

### ステータス報告

`status_report_every` イテレーションごとに通知:
```
[Training] iter={N}/{total} | reward={R} | loss={L} | GPU temp={T}°C | VRAM={M}MB
```

### 早期停止基準

**即座停止（kill & 結果収集）:**
- NaN が `nan_tolerance` 回連続で出現
- CUDA error / OOM error を検出
- loss > `max_loss`
- プロセスクラッシュ（PID_STATUS: dead + 異常終了）

**忍耐切れ停止:**
- reward が `patience_iters` イテレーション間に `min_reward_delta` 以上改善なし
- loss が plateau（同期間内に有意な減少なし）

停止時の通知:
```
[Training] Early stop: {理由} at iter={N} | reward={R} | loss={L}
```

### 外部kill検出

プロセス消失（PID_STATUS: dead）かつ自発停止でない場合:
0. 終了コード `137`（SIGKILL）/`143`（SIGTERM）またはログ内 `Killed` を検出したら `Interrupted` として扱う
1. GPU他者占有をチェック（allowlist外のcompute PIDがあるか）
2. **他者占有あり**: `[Training] 外部killを検出。GPU待機後にリトライします` → GPU待機ループ → リトライ
3. **他者占有なし**: ログを調査して原因特定 → Post-Training（結果分類）へ

### コンテキスト保護

10イテレーションごとにコンテキスト使用率を自己推定する:
- **60%未満**: 続行
- **60%以上**: Training状態を記録してhandoff
  - Training プロセスは **killしない**（バックグラウンドで継続）
  - handoff文書にPID, run_id, logfile, 最新メトリクスを記録
  - `[Training] コンテキスト圧迫のためhandoff（学習プロセスは継続中: PID={pid}）`

---

## Section 4: Post-Training Protocol

### 結果収集

1. `tail -n 200 {logfile}` で最終結果を取得
2. wandb有効（`goal.md` の `wandb.enabled: true`）なら API で詳細メトリクスを取得:
```bash
conda run -n {conda_env} --no-banner python -c "import wandb; api = wandb.Api(); run = api.run('{entity}/{project}/{run_id}'); print(run.summary._json_dict)"
```

### 結果分類

| 結果 | 条件 | 次アクション |
|------|------|------------|
| **Success** | 全iteration完了 or 目標reward達成 | → EVALUATE |
| **Partial** | 忍耐切れ早期停止 | → EVALUATE（停滞コンテキスト付き） |
| **Failed-Recoverable** | OOM | → num_envs半減してリトライ（最大3回） |
| **Failed-Fatal** | NaN, divergence, コードエラー | → EVALUATE（失敗分析付き） |
| **Interrupted** | 外部kill（終了コード 137/143, SIGKILL/SIGTERM, または `Killed`） | → GPU待機 → リトライ（最大2回） |

### リトライ制御

- **Failed-Recoverable**: num_envs を半減して再度 Pre-Launch から実行。最大3回。
- **Interrupted**: GPU待機ループ後に同じ設定で Launch から実行。最大2回。
- リトライ回数超過: Failed-Fatal として EVALUATE へ

### EVALUATE への引き渡し

Post-Training 完了後、以下の情報を添えて Phase 5（EVALUATE）に遷移:
```
[Training] 結果: {Success/Partial/Failed-Fatal}
  - Run ID: {id}
  - Iterations: {completed}/{total}
  - Final reward: {R}
  - Final loss: {L}
  - Log: {logfile}
  {停滞/失敗コンテキストがあれば追記}
```

---

## ルーティングモードとの関係

Training実行は常にCCが担当する（Codexは長時間プロセス管理不可）。
- `codex-heavy` モードでも Training Launch/Monitor はCC
- Codexの関与は EVALUATE での評価のみ
