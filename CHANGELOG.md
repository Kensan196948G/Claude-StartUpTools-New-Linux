# CHANGELOG

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
