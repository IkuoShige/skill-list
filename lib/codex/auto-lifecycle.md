# 自律開発ループ ライフサイクル

## ループ概要

```
DISCUSS → PLAN → IMPLEMENT → TEST → EVALUATE → (CONTINUE or REVISE)
   ↑                                                    |
   └────────────────────────────────────────────────────┘
```

## Phase 1: DISCUSS（問題定義・方針決定）

ルーティングモード（`~/.claude/lib/codex/routing-policy.md`）に応じて動作を分岐する:

**balanced / codex-heavy の場合:**
CC×Codexの構造化議論（/discuss-exec のforkパターン）で以下を決定する:
- ゴールに対してどんな問題を解く必要があるか
- 技術的アプローチの方向性
- リスクと制約の洗い出し

**cc-solo / conservative の場合:**
CCが単独で以下を分析する（Codex呼び出しなし）:
- goal.md を読み、解くべき問題を定義する
- 技術的アプローチの候補を洗い出す
- リスクと制約を整理する

**入力:** goal.md + 前回のEVALUATE結果（初回はなし）
**出力:** 問題定義と方針の合意文書（cc-solo/conservative の場合は CC 分析結果）

## Phase 2: PLAN（タスク分解・実装計画書作成）

DISCUSS の合意に基づき、CC×Codexで実装計画書を作成する。

計画書の内容:
- マイルストーン分割
- 各タスクの担当割り当て（CC / Codex）
- タスク間の依存関係
- 各タスクの完了条件
- テストコマンド／検証方法

### 担当割り当て基準

ルーティングモード（`~/.claude/lib/codex/routing-policy.md`）に応じて割り当てを決定する:

**balanced モード（デフォルト）:**
- **Codexに委託:** 設計判断が複雑でトレードオフ分析が必要なタスク / パターン問題（Codexの知識で一発解決） / 大規模リファクタリング・アーキテクチャ変更 / CCのコンテキストに収まりきらない広範な変更
- **CCが実装:** 上記以外のすべて

**codex-heavy モード:**
- **Codexに委託:** 原則すべてのタスク
- **CCが実装:** 5行以内の自明な変更のみ（設計判断不要なもの）

**cc-solo モード:**
- **CCが実装:** 全タスク（Codex委託なし）

**conservative モード:**
- **CCが実装:** 全タスク（Codex委託なし）
- マイルストーンを最小限に絞る（必須タスクのみ）

**保存先:** `{project}/.claude/plan.md`

## Phase 3: IMPLEMENT（実装）

計画書のタスクを順番に実行する。

### CCが担当するタスクの場合:
1. plan.md から次の未完了CCタスクを取得
2. タスク内容と関連ファイルを読み、直接実装する
3. plan.md のタスクステータスを `[x]` に更新

### Codexに委託するタスクの場合:
1. plan.md から次の未完了Codexタスクを取得
2. /delegate-codex パターンでバックグラウンド委託
3. TaskOutput で結果を自動取得（ポーリング不要、完了まで待機）
4. 結果確認後、plan.md のタスクステータスを `[x]` に更新

### マイルストーン完了時:
→ TESTフェーズに進む

**人間の承認は不要。** CC×Codexの議論（Phase 1, 5）が品質ゲートとして機能する。

## Phase 4: TEST（テスト・検証）

goal.md に定義されたテストコマンドを実行する。
- ユニットテスト、統合テスト
- 学習の実行（MLプロジェクトの場合）
- ビルド確認
- その他プロジェクト固有の検証

### Training Execution Protocol（MLプロジェクトの場合）
plan.md に `[Train]` タスクがある、または goal.md に `## Training Configuration` セクションがある場合:
1. **Pre-Launch**: GPU可用性チェック、VRAM予算計算
2. **Launch**: バックグラウンドで起動（`HOLO_RUN_ID` 付与）
3. **Monitor**: ポーリングループでリアルタイム監視・早期停止判定
4. **Post-Training**: 結果収集・分類（Success / Partial / Failed / Interrupted）
→ 詳細は `~/.claude/lib/codex/training-execution-policy.md` 参照

**出力:** テスト結果・ログを収集

## Phase 5: EVALUATE（進捗評価・議論）

ルーティングモードに応じて動作を分岐する:

**balanced / codex-heavy の場合:**
テスト結果をもとに、CC×Codexで構造化議論を行う:
- ゴールに対してどこまで到達したか
- テスト結果は期待通りか
- 発見された問題・想定外の挙動

**cc-solo / conservative の場合:**
CCが単独でテスト結果を評価する:
- ゴール到達度を自力で分析
- テスト結果と期待値の差分を整理
- conservative の場合は早期handoffを積極的に判断

**判定:**
- **順調** → Phase 3 に戻り、計画書の次のタスク/マイルストーンへ
- **問題あり** → Phase 1 に戻り、再議論・計画修正
- **ゴール達成** → 完了報告（`Bash("mkdir -p {project}/.claude && touch {project}/.claude/auto-done && rm -f {project}/.claude/auto-resume.md")` を実行）
- **セッション長期化** → /handoff を提案

## セッション保護（クロスカッティング）

Phase 遷移のたびに以下の3つを確認する。1・2がトリガーしたら即 handoff。

### 1. コンテキスト使用率チェック
- 60%+ で handoff（`~/.claude/lib/codex/handoff-trigger-policy.md`）
- context compression 通知 → 即 handoff

### 2. バジェットチェック
- `~/.claude/lib/codex/budget-policy.md` に従い、日次消費量が上限に到達したら handoff
- `unlimited` モード時はスキップ

### 3. ルーティングモード再評価
- `~/.claude/lib/codex/routing-policy.md` のモード再評価手順に従う
- 手動オーバーライド時はスキップ
- `unlimited` モード時も実行する（バジェットチェックとは独立）
- モード変更時は `[Routing] {旧モード} → {新モード} に切替` と通知

## 状態管理

### plan.md のタスクステータス
- `[ ]` 未着手
- `[>]` 進行中
- `[x]` 完了
- `[!]` 問題あり（EVALUATE で差し戻し）

### ループ状態
現在のフェーズとタスク位置は plan.md 自体が保持する。
セッション跨ぎは /handoff + plan.md で復元可能。
