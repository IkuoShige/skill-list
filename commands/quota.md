# Session Usage Check

Claude Code, Codex, Copilot の残りセッション量を codexbar で取得して報告する。

## プロバイダ別ソース設定

| Provider | Source | 備考 |
|----------|--------|------|
| codex    | `--source cli` | codex CLI 経由 |
| claude   | `--source oauth` | CC内ではネスト制約で cli 不可 |
| copilot  | `--source web` | macOS のみ対応。Linux ではエラーになるので graceful に報告 |

## 手順

1. 引数 `$ARGUMENTS` に応じて対象プロバイダを決定する:
   - `codex`: Codex のみ
   - `claude`: Claude のみ
   - `copilot`: Copilot のみ
   - `cost`: codex + claude + copilot に加えコスト情報も取得
   - `all`: 全プロバイダ取得（`--provider all --source cli`）
   - 引数なし: codex + claude の2つを取得（デフォルト）

2. 対象プロバイダのコマンドを**並列**で実行する:
   ```
   codexbar usage --provider codex --source cli --format json --pretty
   codexbar usage --provider claude --source oauth --format json --pretty
   codexbar usage --provider copilot --source web --format json --pretty
   ```

3. JSON結果を解析し、以下のフォーマットで報告する:

```
## Session Usage

| Provider | Session (5h) | Weekly (7d) | Plan |
|----------|-------------|-------------|------|
| Codex    | XX% left    | XX% left    | Plus |
| Claude   | XX% left    | XX% left    | Max  |
| Copilot  | XX% left    | XX% left    | Pro  |

### Details
- **Codex Session**: resets at HH:MM (in Xh Xm)
- **Codex Weekly**: resets at DATE (in Xd Xh)
- **Claude Session**: resets at HH:MM (in Xh Xm)
- **Claude Weekly**: resets at DATE (in Xd Xh)
- **Copilot Session**: resets at HH:MM (in Xh Xm)
- **Copilot Weekly**: resets at DATE (in Xd Xh)
```

4. usedPercent を "残り" に変換する: `残り = 100 - usedPercent`

5. 警告ルール:
   - 残り 20% 以下: "LOW" と表示
   - 残り 10% 以下: "CRITICAL" と表示
   - エラーが発生した場合: エラー内容を簡潔に報告し、取得できたプロバイダだけ表示する（copilot の macOS 制約エラーなど）

6. `cost` 引数の場合、追加で以下も実行:
   ```
   codexbar cost --format json --pretty
   ```
   結果をテーブルの下に追記する。
