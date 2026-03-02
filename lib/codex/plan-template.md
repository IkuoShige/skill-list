# 実装計画書テンプレート

DISCUSS フェーズの合意に基づき、以下の形式で `{project}/.claude/plan.md` に保存する。

```markdown
# Implementation Plan
Created: {date}
Goal: {goal.md の目標を1行で}
Status: IN_PROGRESS / REVISING / COMPLETED

## 方針
（DISCUSS で合意したアプローチの要約）

## Milestone 1: {名前}
### Task 1.1 [CC] [ ] {タスク名}
- 内容: ...
- 完了条件: ...
- 関連ファイル: ...

### Task 1.2 [Codex] [ ] {タスク名}
- 内容: ...
- 完了条件: ...
- 委託理由: （なぜCodex向きか）

### Task 1.3 [Train] [ ] {トレーニング実行タスク名}
- 内容: ...
- プリセット: {preset}
- num_envs: {N}
- 成功条件: {reward >= X or 他の基準}
- 関連ファイル: ...

## Milestone 2: {名前}
### Task 2.1 [CC] [ ] {タスク名}
...

## テスト計画
- Milestone 1 完了時: `{コマンド}`
- Milestone 2 完了時: `{コマンド}`
- 全体完了時: `{コマンド}`

## 変更履歴
- {date}: 初版作成
- {date}: EVALUATE結果を受けて Milestone 2 を修正
```

## ステータス記号
- `[ ]` 未着手
- `[>]` 進行中
- `[x]` 完了
- `[!]` 問題あり（要再議論）

## タスクタイプ
- `[CC]` CCが直接実装するタスク
- `[Codex]` Codexに委託するタスク
- `[Train]` Training Execution Protocol で実行するタスク（GPU管理・監視・早期停止含む。詳細は `training-execution-policy.md`）
```
