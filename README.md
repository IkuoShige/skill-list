# Claude Code Skills: Auto-Loop System

Claude Code (CC) と Codex を連携させた自律開発ループのスキル群。

## 構成

```
~/.claude/
├── CLAUDE.md                  # グローバル指示（CC が読む）
├── commands/                  # スラッシュコマンド
│   ├── auto.md               # /auto — 自律開発ループ
│   ├── delegate-codex.md     # /delegate-codex — Codex委託
│   ├── discuss-exec.md       # /discuss-exec — CC×Codex議論
│   ├── handoff.md            # /handoff — セッション引き継ぎ
│   ├── review-codex.md       # /review-codex — Codexレビュー
│   └── quota.md              # /quota — 使用量チェック
├── lib/codex/                 # ポリシー・テンプレート
│   ├── auto-lifecycle.md     # ループの5フェーズ定義
│   ├── budget-policy.md      # 日次バジェット管理
│   ├── routing-policy.md     # CC/Codex ルーティング判定
│   ├── training-execution-policy.md  # GPU学習の自律実行・監視
│   ├── handoff-trigger-policy.md     # Handoff客観指標
│   ├── handoff-memory-template.md    # 引き継ぎ文書テンプレート
│   ├── handoff-resume-prompt.md      # セッション再開プロンプト
│   ├── goal-template.md      # goal.md テンプレート
│   ├── plan-template.md      # plan.md テンプレート
│   ├── delegate-lifecycle.md # Codex委託フロー
│   ├── codex-common.md       # Codex共通設定
│   ├── discuss-prompts.md    # 議論プロンプト
│   ├── review-prompt-template.md     # レビュープロンプト
│   └── review-severity-policy.md     # レビュー重大度基準
└── scripts/
    └── auto-loop.sh          # Handoff跨ぎ自動再起動ラッパー
```

## セットアップ

### 前提ツールのインストール
```bash
#!/bin/bash

# nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
source /root/.bashrc
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Node.js
nvm install --lts

# Claude Code + Codex
curl -fsSL https://claude.ai/install.sh | bash -s latest
npm install -g @openai/codex
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# CodexBar CLI（セッション使用量の把握に必要）
wget https://github.com/steipete/CodexBar/releases/download/v0.18.0-beta.3/CodexBarCLI-v0.18.0-beta.3-linux-x86_64.tar.gz
tar -xzf CodexBarCLI-v0.18.0-beta.3-linux-x86_64.tar.gz
mv CodexBarCLI /usr/local/bin/codexbar
chmod +x /usr/local/bin/codexbar
rm CodexBarCLI-v0.18.0-beta.3-linux-x86_64.tar.gz
apt update && apt install -y libsqlite3-0
```

### Codex側の設定（必須）
CC×Codex連携には `~/.codex/AGENTS.md` が必要。以下の内容で作成する:

```bash
mkdir -p ~/.codex
cat > ~/.codex/AGENTS.md << 'EOF'
# 役割
あなたはCodex、開発プロジェクトの司令塔。
- 設計・計画・レビュー・問題定義を担う
- 実装はClaude Code（CC）が行う。あなたは方針を出し、成果物を評価する

# 知的誠実性を守る
- 相手の主張に同意する前に、まずその主張の最も弱い点を特定せよ
- 弱点が見つからないなら、自分の理解が浅い可能性を疑え
- 「妥当」「同意」は結論であり、出発点ではない
- 迎合は合意ではない。早すぎる収束は思考の放棄である
EOF
```

## 使い方

### 基本
プロジェクトに `{project}/.claude/prompts/goal.md` を書いて `/auto` を実行する。

### /auto の引数
- `unlimited` — バジェットチェック無効
- `budget=N` — 日次バジェット N%
- `balanced` / `codex-heavy` / `cc-solo` — ルーティングモード指定

### ループ
```
DISCUSS → PLAN → IMPLEMENT → TEST → EVALUATE → (繰り返し or 完了)
```

### Training（MLプロジェクト）
`goal.md` に `## Training Configuration` を書くと、Phase 4 で GPU管理・監視付きの
自律学習実行が有効になる。共有GPUでの他ユーザー検出、VRAM自動調整、早期停止を含む。

## 自動再起動
```bash
~/.claude/scripts/auto-loop.sh /path/to/project
```
Handoff → 新セッション起動 → 再開が自動で回る。
