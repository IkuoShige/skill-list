# goal.md テンプレート

ユーザーが `{project}/.claude/prompts/goal.md` に以下の形式で記述する。

```markdown
# Project Goal

## 目標
（何を達成したいか。1-3文で）

## 完了条件
（ゴール達成を判定できる客観的な条件。箇条書き）
- 条件1
- 条件2

## 制約
（技術的制約、時間制約、使用ライブラリ等）
- 制約1
- 制約2

## テストコマンド
（各マイルストーンで実行する検証コマンド）
- `pytest tests/`
- `python train.py --dry-run`
- etc.

## Training Configuration（MLプロジェクトの場合）
### Environment
- conda_env: hsgym       # conda環境名
- simulator: gym          # gym or sim
### Command
- base_command: python train_agent.py
- preset: go2_flat
- default_num_envs: 4096
- min_num_envs: 256
- num_envs_arg_template: "--training.num-envs={N}"
- extra_args: ""
### VRAM Budget
- vram_per_env_mb: 5      # 環境あたりVRAM推定値 (MB)
- vram_overhead_mb: 2000  # フレームワーク固定VRAM (MB)
### Monitoring
- monitoring_interval: 30  # 秒
- status_report_every: 5   # Nイテレーション毎にステータス報告
### Early Stopping
- patience_iters: 200
- min_reward_delta: 1.0
- max_loss: 1e6
- nan_tolerance: 3
### Log Parsing
- reward_pattern: "mean reward:\\s*([+-]?\\d+\\.?\\d*)"
- loss_pattern: "loss:\\s*([+-]?\\d+\\.?\\d*)"
- iter_pattern: "ep\\s+(\\d+)\\s*/\\s*(\\d+)"
- iter_fallback_pattern: "model_(\d{5})\.pt"
### wandb（任意）
- enabled: false
- entity: ""
- project: ""

## 備考
（任意。背景情報、参考資料、過去の試行など）
```
