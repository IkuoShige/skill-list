---
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---
# セッション引き継ぎ
Compatible-With: 1

## 手順
1. **状況収集**
   - `git status`、`git diff --stat`、`git log --oneline -10` をBashで実行し、現在の作業状態を把握する
   - 今セッションで行った作業・決定事項・未解決事項を整理する

2. **引き継ぎ文書生成**
   - Read ~/.claude/lib/codex/handoff-memory-template.md を読み、テンプレートに従って引き継ぎ文書を作成する
   - プロジェクトパスはCCの現在の作業ディレクトリ（pwd）から動的に導出する。ハードコード禁止
   - メモリディレクトリのパスを特定する: CCの自動メモリディレクトリ（`~/.claude/projects/` 配下の、現在のプロジェクトに対応するディレクトリの `memory/`）を使用する

3. **ファイル保存**
   - 要約: メモリディレクトリの `MEMORY.md` を更新する（既存内容がある場合は末尾に追記）
   - 詳細: メモリディレクトリに `handoff-{YYYY-MM-DD-HHMM}.md` を保存する（日時はBashの `date` コマンドで取得）

4. **再開プロンプト表示**
   - Read ~/.claude/lib/codex/handoff-resume-prompt.md を読み、テンプレートに従って再開プロンプトを生成する
   - 詳細ファイルの絶対パスを埋め込む
   - コードブロックで表示する

## 制約
- 自動的に次のアクションは起こさない（保存と表示のみ）
- プロジェクトパスのハードコード禁止
