# CHANGELOG

## [Unreleased]

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
