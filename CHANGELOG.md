# CHANGELOG

## [Unreleased]

### Changed

- 🖥️ L1「ローカル即起動 (フォアグラウンド)」の一回 5 時間制限を撤廃し、既定を無制限へ変更。
  - 新設定 `supervisor.defaults.foregroundSessionMinutes`（`0` = 無制限、既定 `0`）。
    分数を区切りたい場合はこのキーか `start-claude.sh --duration` で指定する。
  - foreground は `CCSU_MAX_SESSION_MINUTES`（300 分）の分数上限チェック対象外へ
    （人間が対話する前提のため）。同時実行セッション数上限 (`CCSU_MAX_SESSIONS=4`) は維持。
  - S1 / cron / supervisor の自律実行は従来どおり 300 分ガードを維持（省クレジット運用）。
  - `duration=0` は GNU coreutils `timeout` の「0 = タイムアウト無効化」仕様で無制限として機能。
    background への `--duration 0` 指定は明示エラーで拒否。

### Added

- 🔁 検証ループのスキル化（Anthropic ブログ 2026-07-22 準拠、`docs/claude/18_検証ループ運用.md` 正本）。
  - `.claude/skills/` を `<name>/SKILL.md` ディレクトリ形式へ移行
    （flat `.md` は Claude Code のスキル自動発見対象外と実証・移行後に認識を確認）。
  - `/verify-startuptools` 新設: bash 構文・bats/node テスト・テンプレート整合性・
    正本/テンプレ同期・secret 確認を PASS まで反復する本リポジトリ固有の検証ループ。
  - 配布 starter スキル `verify-app` 新設（`Claude/templates/claude/skills/`）。
    `lib/template-sync.sh` が登録プロジェクトの `.claude/skills/` へ
    存在しない場合のみ配布（プロジェクト側カスタマイズ保護）。
  - claudeos `verification-loop` スキルをブログ準拠に改訂
    （4 起動形態 standalone / embedded / chained / on-every-PR、スキル化 6 ステップ、
    修正上限 → BLOCKED のループ規則。正本と配布テンプレートを同期）。

### Removed

- `bin/monitor-sessions.sh`（🎛️ コントロールセンター / `claudeos-monitor`）とそのテスト
  `tests/bats/unit/monitor-sessions.bats` を完全削除。監視・起動・Supervisor・介入を
  1 画面に統合する `MO` メニュー項目も撤去。
  - 代替: セッション状態監視は `libexec/watch-session.sh`（メニュー項15）、
    接続・介入は `tmux attach -t claudeos-<project>`、Supervisor 全適用は
    `bin/autonomy.sh start --all`。
  - 副作用: 同ファイルが内包していた `mon__agents_waiting()`（Managed Agents の
    `waitingFor` 可視化）も併せて消失。waitingFor は `claude agents --json` を直接参照する。

## [4.0.0-linux] - 2026-06-07

### Added

- Linux ローカル専用の Claude Code 起動経路。
- `/home/kensan/Projects` 配下の Git リポジトリ候補検出。
- `bin/autonomy.sh start --all` / `stop --all` による Supervisor 全適用。
- `bin/monitor-sessions.sh` の `[a]` 全監督、`[n]` 数字付き個別選択。
- CTO Claude 自律開発と人間最終決断の境界をテンプレートへ明記。
- Ubuntu CI、Bats、Node test、shellcheck。

### Changed

- 参照リポジトリから Linux 実行系を移植し、設定初期値を Linux 向けへ変更。
- 運用メニューの灰色表示を避けるため、互換色変数を白表示へ変更。
- README、docs、tests README、Source of Truth を Linux 版へ刷新。

### Removed

- `.ps1`、`.psm1`、`.bat` ファイル。
- SSH 接続、リモート配布、PTY bridge、旧Windows/PowerShell CI。
- Codex/Copilot 起動ドキュメントと旧フェーズ文書。
