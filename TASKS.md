# TASKS

## Done

- [x] 参照リポジトリを Linux 新規リポジトリへ移植
- [x] SSH/Windows/PowerShell 起動経路を削除
- [x] `/home/kensan/Projects` 配下の Git リポジトリを候補化
- [x] Supervisor 全適用と数字付き個別選択を実装
- [x] CTO Claude 自律開発と人間最終決断の境界を明文化
- [x] Ubuntu CI、Bats、shellcheck を整備
- [x] ClaudeOS v5.0 Ship Native（Experimental）実装・検証（詳細: `docs/architecture/SHIP_DEVELOPMENT_STATUS.md`）

## Ship Native — 人間承認待ち（番号は完成報告書と共通）

- [x] #1 中央 GITHUB_POLICY への Ship Native 適用除外（方式 B）— 中央 PR [#185](https://github.com/Kensan196948G/Deep-Seek-Harness-Project/pull/185) を 2026-11-24 にユーザーがマージ（中央 `db62ffa`）。本リポジトリのミラーは PR [#231](https://github.com/Kensan196948G/Claude-StartUpTools-New-Linux/pull/231) で同期済み（`ab43d3c`）
- [ ] #2 横断自動マージ巡回から本リポジトリを除外
- [x] #3 ruleset に `claudeos/local-quality`・`claudeos/human-approval` を必須追加（第 1 段階）— 2026-11-24 20:30 にユーザーが適用。確認用 PR #234 で、Actions の必須 2 件が success でも承認ステータスが無ければ `BLOCKED` になることを確認（マージせず閉じた）。第 2 段階（`integration_id` 限定）は #4・#7 とセットで保留
- [ ] #4 人間専用 GitHub App の作成と integration_id 限定 — **保留（2026-11-24 判断）**。AI の gh トークンが admin 権限を持つ間は ruleset ごと書き換えられ効果が限定的なため、#7（AI の別 OS ユーザー化）・トークン分離とセットで後日検討
- [ ] #5 週次の全履歴シークレット走査の実施方式
- [ ] #6 並走比較後に `linux-validate`・gitleaks を必須から外す
- [ ] #7 AI エージェントを sudo 無しの別 OS ユーザーで実行（あわせて AI 用 gh トークンを admin 権限なしに分離する。#4 はこの後）
- [x] #8 PreToolUse(Bash) フックの扱い — 案 A を PR [#229](https://github.com/Kensan196948G/Claude-StartUpTools-New-Linux/pull/229) としてユーザーがマージ（`4bf8a55`）。各 clone で `bash scripts/setup/install-githooks.sh` が必要
- [x] #9 gh を 2.63 以上へ更新 — 2026-11-24 に 2.105.0 へ更新（公式 deb・sha256 検証済み・`apt-mark hold gh`）
- [x] #10 承認者鍵の作成・登録（bootstrap）— 承認者 Kensan の公開鍵を PR [#232](https://github.com/Kensan196948G/Claude-StartUpTools-New-Linux/pull/232) で登録済み（`config/ship-policy.json` の `humanGate.approverKeys`）
- [ ] #11 本 PR の最終マージ承認

## Next

- [ ] 実運用で `bash bin/autonomy.sh start --all --dry-run` の対象を確認
- [ ] 必要に応じて `config/config.json` の `localExcludes` を調整
- [ ] GitHub Actions 初回実行結果を確認
- [ ] 実プロジェクト1件で Supervisor 個別適用を試験
