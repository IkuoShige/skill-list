# セッションバジェットポリシー

## 概要
`/auto` ループ中に quota を使い切らないよう、消費ペースを管理する。
2つのレートリミット窓（5時間 primary / 7日 secondary）を考慮する。

## 日次バジェット計算

### 動的計算（デフォルト）
codexbar の `secondary.resetsAt` から残り日数を算出し、日次バジェットを動的に決定する:
```
remaining_days = ceil((secondary.resetsAt - now) / 24h)   # 最小1
weekly_remaining = 100 - secondary.usedPercent
daily_budget = weekly_remaining / remaining_days
```

**例:**
| weekly remaining | 残り日数 | daily_budget |
|-----------------|---------|-------------|
| 100% | 7日 | 14%（従来と同じ） |
| 80% | 4日 | 20% |
| 50% | 2日 | 25% |
| 100% | 1日 | 100%（最終日は使い切れる） |

### 手動上書き
`/auto budget=N` で固定値を指定可能。動的計算を無効化する。

## スナップショット取得

`/auto` 初期化時に以下を並列実行し、baseline を記録する:
```
codexbar usage --provider codex --source cli --format json
codexbar usage --provider claude --source oauth --format json
```

記録する値（プロバイダごと）:
- `snapshot_weekly_usedPercent`: 開始時の `secondary.usedPercent`
- `weekly_resetsAt`: `secondary.resetsAt`（日次バジェット計算用）
- `primary_resetsAt`: `primary.resetsAt`（5時間窓リセット時刻）
- `primary_usedPercent`: `primary.usedPercent`（5時間窓の消費率）

取得失敗時はそのプロバイダのバジェットチェックをスキップする（ループは止めない）。

## バジェットチェック手順

### チェックタイミング
各 Phase 遷移時（DISCUSS→PLAN→IMPLEMENT→TEST→EVALUATE の切り替わり）に1回実行する。

### チェック手順
1. codexbar で現在の usage を取得（スナップショットと同じコマンド）
2. **日次バジェット再計算**: 現在時刻と `secondary.resetsAt` から `daily_budget` を更新
3. セッション消費量を計算: `consumed = current_weekly_usedPercent - snapshot_weekly_usedPercent`
4. **両プロバイダのうち大きい方**の consumed を採用する
5. 判定テーブルに基づきアクション実行
6. **ルーティングモード再評価をトリガー**: 取得した weekly remaining を `~/.claude/lib/codex/routing-policy.md` のモード決定マトリクスに照合し、モード変更が必要か判定する（手動オーバーライド時はスキップ）

### 判定テーブル

| consumed vs daily_budget | アクション |
|--------------------------|----------|
| < 80% | 続行（表示なし） |
| >= 80%, < 100% | 警告表示して続行 |
| >= 100% | handoff 実行 |

### 5時間窓レートリミット検出
Phase 遷移時に `primary.usedPercent` も確認する:
- **primary.usedPercent >= 80%**: レートリミット接近。handoff を実行し、リセット待ち後に自動再開する
- handoff 時に `{project}/.claude/auto-rate-limit-wait.json` を作成:
```json
{
  "resetsAt": "{primary.resetsAt}",
  "reason": "5h rate limit",
  "weekly_consumed": "{consumed}%",
  "daily_budget": "{daily_budget}%"
}
```
- `auto-loop.sh` がこのファイルを検出し、リセット時刻まで待機してから再開する

## メッセージテンプレート

### 警告（80%到達時）
```
[Budget] ⚠ 日次バジェットの {consumed_pct}% を消費済み（{consumed}% / {daily_budget}%）。残り {remaining}% で handoff します。
```

### Handoff（100%到達時）
```
[Budget] 日次バジェット {daily_budget}% に到達しました（消費: {consumed}%）。セッションを引き継ぎます。
```

### レートリミット待ち
```
[Budget] 5時間窓レートリミット接近（primary: {primary_used}%）。{resetsAt} のリセットまで待機します。
```

### 初期化メッセージ
```
[Budget] 日次バジェット: {daily_budget}%（残{remaining_days}日）| Codex weekly: {codex_used}% used | Claude weekly: {claude_used}% used
```

### unlimited モード時
```
[Budget] unlimited モード — バジェットチェック無効
```

## unlimited モード
`/auto unlimited` で起動した場合:
- スナップショット取得をスキップ
- 全バジェットチェックをスキップ
- 初期化時に unlimited メッセージのみ表示

## Training中のバジェット消費
- Training監視中のAPI quota消費は低い（短い `tail` / `nvidia-smi` の呼び出しのみ）
- ただしコンテキスト蓄積が大きいため、10イテレーション毎にコンテキスト使用率をチェック
- バジェットチェックはPhase遷移時のみ実行する（監視ループ内では行わない）
