---
allowed-tools: Bash, Task
---
# Claude×Codex 議論（exec版）
テーマ: $ARGUMENTS
Compatible-With: 1

## Codex呼び出し
全Codex呼び出しをTask tool（subagent_type: "general-purpose"）にforkする。
サブエージェントが _details/codex-common.md のforkプロトコルに従い、thread_id + 応答テキストのみを返す。
メインコンテキストに詳細ファイル内容を載せない。

## プロンプト解決
プロジェクトローカルを優先: `{project}/.claude/prompts/discuss-prompts.md` → なければ `~/.claude/lib/codex/discuss-prompts.md`

## 手順
1. **[fork] 問い定義依頼**
   Task fork → "~/.claude/lib/codex/codex-common.md と ~/.claude/lib/codex/discuss-prompts.md を読め。ステップ1テンプレートの {theme} に以下を埋めよ: '{テーマ}'。codex exec --json --skip-git-repo-check で実行し、forkプロトコルの形式で thread_id と response を返せ"
   → thread_idを記録する

2. **CC独自立場生成** — Codexの問い定義のみに基づき独立して初期立場を生成する（アンカリング防止）

3. **[fork] Codex独自立場生成**
   Task fork → "codex-common.md と discuss-prompts.md を読め。ステップ3テンプレートで codex exec resume {thread_id} --json を実行。responseを返せ"

4. **[fork] 批評・論点整理**
   Task fork → "discuss-prompts.md のステップ4テンプレートに {cc_position}=CCの立場, {codex_position}=Codexの立場 を埋め、codex exec resume {thread_id} --json で実行。responseを返せ"

5. **CCの応答** — Codexの批評に対してCCが応答する

6. **合意点・相違点・修正案** — 毎ラリーで明示する

7. **ラリー継続** — 完全合意まで。無理な妥協は禁止
   各Codexラリーは同様にfork → "discuss-prompts.md のRallyテンプレートに {cc_response}=CCの応答 を埋め、resume {thread_id} で実行。responseを返せ"

8. **[fork] 合意構造化**
   Task fork → "discuss-prompts.md のステップ8テンプレートで resume {thread_id} を実行。responseを返せ"

9. **結果提示** — CCがユーザーに合意結果を提示する
