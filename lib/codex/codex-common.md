# Codex共通実行契約
Contract-Version: 1

## 呼び出しパターン
- MCP不使用。Bash経由で `codex exec` を使う
- 初回: `codex exec --json --skip-git-repo-check [--full-auto] "プロンプト"` → JSONL出力からthread_idを取得（CCの現在の作業ディレクトリで実行される。--skip-git-repo-checkは非gitディレクトリでのフォールバック用。--full-autoはCodexにファイル操作を許可する場合に付与）
- 継続: `codex exec resume <thread_id> --json "プロンプト"` でセッション継続
- `--last` は誤ったセッションを拾うため禁止。必ずthread_idを明示指定する

## JSONL解析ルール
- `{"type":"thread.started","thread_id":"..."}` からthread_idを抽出する
- `{"type":"item.completed","item":{"type":"agent_message","text":"..."}}` からCodexの応答を抽出する
- 複数行のJSONL出力は1行ずつパースする。不正なJSON行はスキップする

## thread_id管理
- 初回呼び出しで取得したthread_idを記録し、同一タスク内のすべての継続呼び出しで使用する
- thread_idは呼び出し元コマンドが管理する（この契約は保持しない）

## タイムアウト
- デフォルト: 300秒（5分）
- Bashのtimeoutパラメータで設定する

## エラー処理
- codex execが非0で終了した場合、stderrの内容をユーザーに提示する
- thread_idが取得できなかった場合、JSONL出力全体をユーザーに提示して診断を依頼する
- タイムアウト時は「Codexが応答時間内に完了しませんでした」と報告する

## forkプロトコル
Codex呼び出しはTask tool（subagent_type: "general-purpose"）にforkし、メインコンテキストを汚染しない。

サブエージェントの手順:
1. このファイル（codex-common.md）の呼び出しパターンとJSONL解析ルールに従う
2. 指定されたプロンプトテンプレートファイルを読み、変数を埋める
3. codex exec を実行する（Bash timeout: 300000ms）
4. JSONL出力を1行ずつ解析し thread_id と response を抽出する
5. 以下の形式で返す:

```
thread_id: <id>
---
<response text>
```

6. エラー時は `error: <message>` を返す。JSONL解析失敗時は生出力を返す
