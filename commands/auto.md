---
allowed-tools: Bash, Task, Read, Write, Edit, Glob, Grep
---
# 自律開発ループ
Compatible-With: 1

## 引数
`$ARGUMENTS` を解析する:
- `unlimited`: バジェットチェック無効
- `budget=N`: 日次バジェットを N% に設定（デフォルト: 14）
- `balanced`: ルーティングモードを balanced に強制
- `codex-heavy`: ルーティングモードを codex-heavy に強制
- `cc-solo`: ルーティングモードを cc-solo に強制
- 引数なし: バジェット管理有効（デフォルト 14%）、ルーティングモードは自動選択
- 組合せ可: 例 `/auto codex-heavy unlimited`

## 初期化
1. `{project}/.claude/prompts/goal.md` を読む。なければユーザーに作成を依頼して終了
2. `{project}/.claude/plan.md` の有無を確認する
   - **あり:** plan.md を読み、次の未完了タスクから再開（Phase 3へ）
   - **なし:** Phase 1へ
3. **バジェット初期化**（`~/.claude/lib/codex/budget-policy.md` に従う）:
   - `unlimited` の場合: `[Budget] unlimited モード — バジェットチェック無効` と表示してスキップ
   - それ以外: codexbar で codex + claude の weekly usedPercent をスナップショット取得し、初期化メッセージを表示
4. **ルーティングモード決定**（`~/.claude/lib/codex/routing-policy.md` に従う）:
   - 手動指定（`balanced` / `codex-heavy` / `cc-solo`）がある場合: そのモードに固定
   - 指定なし: スナップショットの weekly remaining からモード決定マトリクスで自動選択
   - `[Routing] {mode} モードで開始（Claude remaining: {claude_remaining}%, Codex remaining: {codex_remaining}%）` と表示

## バジェットチェック＆ルーティング再評価（Phase 遷移時共通）
各 Phase に入る前に以下を実行する:
1. `~/.claude/lib/codex/budget-policy.md` のバジェットチェック手順（`unlimited` 時はスキップ）
2. `~/.claude/lib/codex/routing-policy.md` のモード再評価（手動指定時はスキップ、`unlimited` 時も実行）
- バジェット 100% 到達時は「セッション引き継ぎ＆自動再開」に遷移

## Phase 1: DISCUSS（問題定義）
ルーティングモードに応じて動作を分岐する（`~/.claude/lib/codex/routing-policy.md` Phase 1 参照）:
- **balanced / codex-heavy**: goal.md + 前回EVALUATE結果（あれば）をテーマに、/discuss-exec のforkパターンで議論する
- **cc-solo / conservative**: CCが単独で goal.md を分析し、アプローチ・リスク・制約を整理する（Codex呼び出しなし）
- 合意内容（または分析結果）をそのまま Phase 2 の入力にする

## Phase 2: PLAN（実装計画書作成）
DISCUSS の合意（または CC 分析結果）をもとに実装計画書を作成する。
- `~/.claude/lib/codex/plan-template.md` の形式に従う
- 各タスクの [CC] / [Codex] 割り当ては、現在のルーティングモードに従う（`~/.claude/lib/codex/auto-lifecycle.md`）
- `{project}/.claude/plan.md` に保存する
- **承認不要。そのまま Phase 3 へ進む**

## Phase 3: IMPLEMENT（実装）
plan.md の次の未完了タスクを取得し実行する。

**[CC] タスクの場合:**
- plan.md のタスク内容と関連ファイルを読み、直接実装する（plan mode不要）
- plan.md のステータスを `[x]` に更新

**[Codex] タスクの場合:**
- /delegate-codex のforkパターンでバックグラウンド委託
- TaskOutput で結果を待つ（自動ポーリング）
- 結果確認後、plan.md を更新

**各タスク完了後:** コンテキスト使用率を自己推定する。60%+ならマイルストーン途中でもセッション引き継ぎ＆自動再開へ。システムからcontext compression通知が来たら即座にhandoff。

**マイルストーンの全タスク完了時** → Phase 4 へ

## Phase 4: TEST（テスト / トレーニング実行）
goal.md と plan.md のテスト計画に基づき、テストを実行する。
- **`plan.md` に `[Train]` タスクがある、または `goal.md` に `## Training Configuration` がある場合**: `~/.claude/lib/codex/training-execution-policy.md` に従い
  Training Execution Protocol を実行（GPU管理、監視、早期停止含む）
- **通常テストの場合**: テストコマンドを実行し結果・ログを収集（現行通り）

## Phase 5: EVALUATE（進捗評価）
ルーティングモードに応じて動作を分岐する（`~/.claude/lib/codex/routing-policy.md` Phase 5 参照）:
- **balanced / codex-heavy**: テスト結果をもとに /discuss-exec のforkパターンで議論する
  - テーマ: 「テスト結果: {結果要約}。ゴール '{goal}' に対する到達度を評価し、次のアクションを決定せよ」
- **cc-solo / conservative**: CCが単独でテスト結果を評価し、ゴール到達度・問題点を分析する

**合意結果に基づき自動ルーティング:**
- **順調** → Phase 3（次のマイルストーン）
- **問題あり** → Phase 1（再議論・計画修正）
- **ゴール達成** → 完了報告（`Bash("mkdir -p {project}/.claude && touch {project}/.claude/auto-done && rm -f {project}/.claude/auto-resume.md")` を実行）
- **セッション長期化** → セッション引き継ぎ＆自動再開（下記参照）

## セッション引き継ぎ＆自動再開
セッション長期化時またはバジェット到達時は以下の手順で新セッションに引き継ぐ:
1. /handoff の手順に従い状態を保存する（MEMORY.md + 引き継ぎ文書）
2. `{project}/.claude/auto-resume.md` に再開プロンプトを書き出す:
   ```
   前セッションの引き継ぎを読んで作業を再開してください。
   引き継ぎ文書: {handoff詳細ファイルの絶対パス}
   実装計画書: {project}/.claude/plan.md
   /auto を再開してください。
   ```
3. セッションを終了する（ラッパースクリプトがこのファイルを検出して新セッションを起動する）

**ラッパースクリプト:** `~/.claude/scripts/auto-loop.sh [project-dir]` で起動すると、handoff→新セッション起動→再開が自動で回る。

## フェーズ通知
各フェーズ遷移時にユーザーに現在地を1行で通知する（例: `[Phase 3] Task 2.1 [CC] に着手`）。通知のみ、承認は求めない。
