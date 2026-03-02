# Quota-Aware ルーティングポリシー

## 概要
`/auto` ループ中に Claude / Codex の残量に応じてタスク割り当てを動的に切り替える。
残量バランスと問題の複雑さを考慮し、quota を効率的に消費する。

## ルーティングモード（4種）

| モード | 条件 | DISCUSS/EVALUATE | IMPLEMENT | 目的 |
|--------|------|-----------------|-----------|------|
| **balanced** | 両方余裕 (>30%) | CC×Codex 議論 | CC実装 + 複雑タスクはCodex委託 | 通常運用 |
| **codex-heavy** | Claude残少 (<=30%) or 手動指定 | CC×Codex 議論 | 原則Codex委託、CCはオーケストレーションのみ | Claude節約 |
| **cc-solo** | Codex残少 (<=30%) or 手動指定 | CCが単独分析 | CC全実装 | Codex節約 |
| **conservative** | 両方残少 (<=30%) | CCが単独で最小限 | 必須タスクのみCC実装、早期handoff | 両方節約 |

## モード決定マトリクス

`weekly remaining = 100 - weekly usedPercent` で計算する。

| Claude weekly remaining | Codex weekly remaining | → モード |
|------------------------|----------------------|----------|
| > 30% | > 30% | balanced |
| <= 30% | > 30% | codex-heavy |
| > 30% | <= 30% | cc-solo |
| <= 30% | <= 30% | conservative |

## remaining 取得方法

バジェットスナップショットと同じコマンドで取得する:
```
codexbar usage --provider codex --source cli --format json
codexbar usage --provider claude --source oauth --format json
```
`remaining = 100 - weekly usedPercent`

取得失敗時のフォールバック:
- Claude 取得失敗 → Codex の remaining のみで判定（Claude は >30% 扱い）
- Codex 取得失敗 → Claude の remaining のみで判定（Codex は >30% 扱い）
- 両方失敗 → balanced をデフォルトとする

## 手動オーバーライド

`/auto` の引数で強制指定可能。quota 状態に関係なくそのモードを使用する:
- `/auto codex-heavy`: 強制 codex-heavy
- `/auto cc-solo`: 強制 cc-solo
- `/auto balanced`: 強制 balanced（自動選択を無効化）
- 既存引数との組合せ可: `/auto codex-heavy unlimited`

手動オーバーライド時はモード再評価をスキップする（セッション中ずっと固定）。

## モード再評価

### タイミング
- 各 Phase 遷移時のバジェットチェックと同時に実行
- `unlimited` モードでもルーティング再評価は実行する（バジェットチェックのみスキップ）

### 手順
1. codexbar で現在の weekly remaining を取得
2. モード決定マトリクスに照合
3. 現在のモードと異なる場合のみ切替を実行

### 切替通知
モード変更時に以下を表示する:
```
[Routing] {旧モード} → {新モード} に切替（Claude remaining: {claude_remaining}%, Codex remaining: {codex_remaining}%）
```

## Phase 別動作

### Phase 1: DISCUSS

| モード | 動作 |
|--------|------|
| **balanced** | /discuss-exec のforkパターンで CC×Codex 議論（現行通り） |
| **codex-heavy** | /discuss-exec のforkパターンで CC×Codex 議論（現行通り） |
| **cc-solo** | CCが単独で問題分析。goal.md を読み、アプローチ・リスク・制約を自力で整理。Codex呼び出しなし |
| **conservative** | cc-solo と同じ（CCが単独で最小限の分析） |

### Phase 2: PLAN（担当割り当て）

| モード | 割り当て基準 |
|--------|-------------|
| **balanced** | auto-lifecycle.md の従来基準で [CC]/[Codex] を決定 |
| **codex-heavy** | 原則 [Codex]。CCは 5行以内の自明な変更のみ [CC] |
| **cc-solo** | 全タスク [CC] |
| **conservative** | 全タスク [CC]、マイルストーンを最小限に絞る（必須タスクのみ） |

### Phase 3: IMPLEMENT

Phase 2 で決定済みの割り当てに従い実行する。モード固有の追加動作はなし。

### Phase 4: TEST

全モード共通。テストコマンドの実行に変更なし。

### Phase 5: EVALUATE

| モード | 動作 |
|--------|------|
| **balanced** | /discuss-exec のforkパターンで CC×Codex 議論（現行通り） |
| **codex-heavy** | /discuss-exec のforkパターンで CC×Codex 議論（現行通り） |
| **cc-solo** | CCが単独でテスト結果を評価。ゴール到達度・問題点を自力で分析 |
| **conservative** | cc-solo と同じ（CCが単独で最小限の評価）。早期handoffを積極的に判断 |
