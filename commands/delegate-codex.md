---
allowed-tools: Bash, Task, Glob, Grep, Read
---
# Codex委託（セミ並列）
タスク: $ARGUMENTS
Compatible-With: 1

## 手順
1. **コンテキスト収集** — タスクに関連するコード・設計文脈をGlob/Grep/Readで収集する
2. **プロンプト解決** — プロジェクトローカルのプロンプトを優先して読む:
   - 先に `{project}/.claude/prompts/delegate-prompt.md` を探す（Glob）
   - なければ `~/.claude/lib/codex/delegate-lifecycle.md` の委託プロンプトテンプレートにフォールバック
3. **[fork / background]** Codex委託実行
   Task fork（subagent_type: "general-purpose", run_in_background: true）→ "~/.claude/lib/codex/codex-common.md のforkプロトコルを読め。プロンプトテンプレートに変数を埋めよ。codex exec --json --skip-git-repo-check --full-auto で実行し結果を返せ。Codexはファイル操作・コード変更を含む全操作を実行してよい"
4. **ユーザー通知** — 「Codexにバックグラウンドで委託しました」＋委託内容の要約＋「結果確認は "check codex" で」

## 結果確認（"check codex" で発動）
- TaskOutputでバックグラウンドタスクの結果を取得する
- Codexがファイル変更した場合は `git diff --stat` で変更内容を提示する
- 結果を整形してユーザーに提示する

## 制約
- 同時に複数の委託を実行しない
- 自動ポーリングしない
