# Web ターミナル（ブラウザで ClaudeCode を操作）

状態: **適用済み（APPLIED, 2026-09-24）**
正本: 本ファイル。上位方針: `docs/architecture/WEB_STARTUP_PUBLIC_ACCESS.md`、`Cloudflare公開基盤仕様.md`。

## 1. 目的

Web スタートアップコンソール（`WEB_STARTUP_TOOL.md`）は「起動操作」のみで、実行中の ClaudeCode の
CLI 画面が見えない。本機能はブラウザ内に実端末（ttyd）を出し、既存の `claudeos-*` tmux セッションへ
**attach** する。無ければ `bin/start-claude.sh` で **新規起動**してから attach する。

## 2. 構成

```text
ブラウザ (kensan1969@gmail.com)
  │ https://claude-startuptools.mirai-dx-platform.com/terminal/
  ▼
Cloudflare エッジ
  ├─ Access application（既存。hostname 単位で /terminal も保護）
  └─ Tunnel ingress  path ^/terminal → 127.0.0.1:3741
       ▼
  ttyd（systemd --user `claude-startuptools-ttyd.service`, loopback 3741, base-path /terminal）
       └─ bin/web-terminal.sh → tmux attach / bin/start-claude.sh --foreground --tmux
```

## 3. コンポーネント

| 層 | 実体 | 役割 |
|---|---|---|
| 端末 | `ttyd` 1.7.7（静的バイナリ、`~/.local/bin/ttyd`） | PTY + WebSocket + xterm.js |
| アダプタ | `bin/web-terminal.sh` | projectsDir 配下の実在フォルダを検証 → `claudeos-*` へ attach / 新規起動（メニューは全フォルダ） |
| 常駐 | `~/.config/systemd/user/claude-startuptools-ttyd.service` | loopback 3741・base-path `/terminal` |
| 公開 | `config/cloudflare/web-startup-tunnel.yml` の `path: ^/terminal` | 同一 hostname → 既存 Access が保護 |
| UI | `scripts/web/public/{index.html,styles.css}` | 「ブラウザターミナル」導線 |

## 4. 安全設計

| 統制 | 実装 |
|---|---|
| 入口認証 | 既存 Cloudflare Access（`allow: kensan1969@gmail.com` のみ）が hostname 単位で `/terminal` も保護 |
| 露出面 | ttyd は `127.0.0.1:3741` のみ bind（LAN・公開直アクセス不可） |
| 任意シェル禁止 | `web-terminal.sh` は **projectsDir 配下に実在するフォルダ**のみ受ける（`..`・改行・先頭 `-` は拒否）。実行は `tmux attach` / `start-claude.sh` のみ。生のセッション名は受けない（`ccsu_safe_name` から導出） |
| Origin | ttyd `-O`（check-origin）を有効化。ただし本版では実効性が限定的（§7） |
| 同時接続 | `-m 5` |
| url-arg | `-a` を有効化。`?arg=--project&arg=<name>` は `web-terminal.sh` が検証する（存在しないフォルダ・`..`・先頭 `-` は拒否）。任意の引数やシェルは渡せない |
| 監査 | `~/.claudeos/logs/web-startup-audit.log` に `terminal_attach` / `terminal_start` を記録 |
| 書込 | `-W`（対話操作のため必須）。読み取り専用運用にする場合は unit から `-W` を外す |

## 5. 導入手順（人間）

```bash
# 1. ttyd（静的）。apt 版は libwebsockets の evlib_uv プラグイン欠落で起動しないため静的バイナリを使う。
install -m 0755 ttyd ~/.local/bin/ttyd          # 1.7.7-40e79c7 / sha256 8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
"$HOME/.local/bin/ttyd" --version

# 2. unit 配置 + 起動（unit は repo 外。値は §3 のとおり）
systemctl --user enable --now claude-startuptools-ttyd.service

# 3. tunnel ingress に path ^/terminal → 127.0.0.1:3741 を追加して再起動
cloudflared tunnel --config ~/.cloudflared/claude-startuptools-config.yml ingress validate
systemctl --user restart claude-startuptools-cloudflared.service
```

unit の ExecStart（`=` を含む `-t key=value` は systemd が 2 引数に分割するため使わない）:

```ini
ExecStart=/home/kensan/.local/bin/ttyd -i 127.0.0.1 -p 3741 -b /terminal -O -W -a -m 5 -w <repo> <repo>/bin/web-terminal.sh
# -a (url-arg): `/terminal/?arg=--project&arg=<name>` でラッパーへ project を渡せる。
#   コンソールの「全画面 CLI」がこの形で対象セッションへ直接 attach する。
#   受け取る側 (web-terminal.sh) が projectsDir 配下の実在フォルダだけを許可する。
```

## 6. 検証

```bash
ss -ltnp | grep 3741                     # 127.0.0.1:3741 のみであること
bats tests/bats/unit/web-terminal.bats   # フォルダ検証 / attach / 起動 / 監査
```

- 未認証 `https://claude-startuptools.mirai-dx-platform.com/terminal/` → Access ログインへ 302（`redirect_url=/terminal/`）。
- ログイン後 `/terminal/` で端末が表示され、既存セッションへ attach または新規起動できる。

## 7. 残リスク・既知の制約

- ttyd `-O`（check-origin）は本版でクロスオリジン WS を拒否しなかった。主制御は Access（hostname 保護）。
  Access の binding cookie は有効にしてある。
- 端末はホスト上の ClaudeCode セッションを操作できる。Access アカウントの侵害はホストでの操作と等価
  （MFA は IdP 側に依存）。
- 新規起動は `bin/start-claude.sh --foreground --tmux` を通すため Goal Router 等が動き、起動に数秒かかる。
- ttyd は外部バイナリ（サプライチェーン）。版と sha256 を §5 に記録した。
