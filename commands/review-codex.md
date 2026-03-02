---
allowed-tools: Bash, Task
---
# Codexコードレビュー
対象: $ARGUMENTS
Compatible-With: 1

## diff取得ルール（引数判定）
| 引数 | コマンド |
|------|---------|
| `staged` | `git diff --cached` |
| `uncommitted` / 引数なし | `git diff HEAD` |
| `HEAD~N` | `git diff HEAD~N..HEAD` |
| `<commit>` | `git diff <commit>..HEAD` |
| `<file-path>` | `git diff -- <file-path>` |

## 手順
1. Bashで上記ルールに従いdiffを取得する。diffが空なら「レビュー対象の変更がありません」と報告して終了
2. diffが5000行超の場合は警告し、ファイル単位での分割レビューを提案する
3. **プロンプト解決** — プロジェクトローカルを優先:
   - 先に `{project}/.claude/prompts/review-prompt.md` を探す（Glob）
   - なければ `~/.claude/lib/codex/review-prompt-template.md` にフォールバック
4. **[fork]** Codexレビュー実行
   Task fork（subagent_type: "general-purpose"）→ "~/.claude/lib/codex/codex-common.md のforkプロトコルと、解決済みプロンプトテンプレートと、~/.claude/lib/codex/review-severity-policy.md の表示ルールを読め。staged/uncommittedなら codex exec review --json --skip-git-repo-check --uncommitted を実行。それ以外なら固定プロンプトテンプレートに diff を埋めて codex exec --json --skip-git-repo-check で実行。応答をP0/P1/P2形式に整形して返せ"
5. fork結果をユーザーに提示する

## 制約
- 自動修正は行わない（レビュー結果の提示のみ）
- 修正はユーザーの指示を待つ
