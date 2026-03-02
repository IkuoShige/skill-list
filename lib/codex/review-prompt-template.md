# レビュープロンプト構築テンプレート

## diff取得方法

引数に応じて対象diffを決定する:

| 引数 | diffコマンド | 説明 |
|------|-------------|------|
| `staged` | `git diff --cached` | ステージ済み変更 |
| `uncommitted` | `git diff HEAD` | 未コミットの全変更（staged + unstaged） |
| `HEAD~N` | `git diff HEAD~N..HEAD` | 直近N件のコミット |
| `<commit>` | `git diff <commit>..HEAD` | 指定コミットからHEADまで |
| `<file-path>` | `git diff -- <file-path>` | 特定ファイルの変更 |
| （引数なし） | `git diff HEAD` | デフォルトは uncommitted |

## Codex Review機能の使用

staged/uncommittedの場合は `codex exec review` を優先する:
```
codex exec review --json --skip-git-repo-check --uncommitted
```

それ以外（コミット範囲指定等）の場合は汎用の `codex exec` でdiffを渡す:
```
codex exec --json --skip-git-repo-check "以下のdiffをレビューしてください。P0/P1/P2の深刻度で分類し、各指摘にファイル名と行番号を付けてください。\n\n<diff>\n$(git diff ...)\n</diff>"
```

## Codex固定プロンプト（コミット範囲指定時）

```
以下のdiffをレビューしてください。

## レビュー要件
- 各指摘をP0(critical)/P1(important)/P2(suggestion)に分類すること
- 各指摘にファイル名と行番号を付けること
- P0は最初に報告すること
- 修正案がある場合はコードブロックで提示すること
- 最後にサマリー（P0: N件 | P1: N件 | P2: N件）を付けること

{context_section}

## Diff
{diff_content}
```

- `{context_section}`: 変更の文脈が分かる場合は `## 変更の文脈\n{説明}` を埋める。不明な場合は空
- `{diff_content}`: git diffの出力をそのまま埋める

## ガイドライン
- diffが空の場合はレビュー不要と報告して終了する
- diffが大きすぎる場合（5000行超）は警告を出し、ファイル単位での分割レビューを提案する
