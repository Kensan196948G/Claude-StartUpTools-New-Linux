# Ship Native 開発状況（永続化された進捗）

最終更新: 2026-11-24 / **main `2bf919d` にマージ済み**（PR #228）。関連: PR #229（`4bf8a55`）、中央 PR #185（`db62ffa`）

コンテキストが縮小・再起動された場合は、まず本書を読んで再開する。

## 1. フェーズ

| Phase | 内容 | 状態 |
| --- | --- | --- |
| 0 | 現状分析・環境確認（公式仕様取得・実機確認） | ✅ |
| 1 | アーキテクチャ・ADR 相当（`SHIP_NATIVE_ARCHITECTURE.md`） | ✅ |
| 2 | Ship Capability / Integration（`capability.js`・`ship.js`） | ✅（/ship の実機セッション検証は未 = 人が行う） |
| 3 | Local Quality Engine（隔離・封印・Commit Status） | ✅ 実リポジトリで PASS 実測 |
| 4 | AI Quality Gate | ✅ |
| 5 | Human Gate & Auto Merge（実装・変更案） | ✅ 実装 / ⏳ 施行は人間承認 |
| 6 | Supervisor・起動モード統合（SH1〜SH5/QC/HG、monitor） | ✅（既定モードの SH2 化は未 = 実機検証後） |
| 7 | Web Console（Ship Control Center） | ✅ |
| 8 | DB・監査（0006・射影・hash 連鎖） | ✅（本番 DB へは未適用） |
| 9 | セキュリティ（敵対的テスト・TLA+） | ✅ |
| 10 | 総合テスト | ✅ |
| 11 | ドキュメント | ✅ |
| 12 | 本リポジトリへの /ship 適用 | ❌ 実施不能（下記 §4） |
| 13 | 人間承認・マージ | ✅ #185・#229・#228 をユーザーがマージ（自動マージの施行は未: 鍵登録 #10・ruleset #3・`centralProfileEnforced`） |

## 2. 実測結果（2026-11-24）

| 検証 | 結果 |
| --- | --- |
| `npm test`（bats 1447 + node 636） | 全件 PASS（失敗 0・skip 0） |
| `npm run lint` / `test:dry-run` / adversarial probe | PASS |
| Ship 追加テスト（node: core 25・human-gate 30・quality 10・lifecycle 5・ship-api 15・project-to-db 16 / bats: ship 16・control-db-0006 9） | 全件 PASS |
| TLA+ `ship_gate.tla`（承認なしマージ不可・SHA 固定・nonce 1 回） | verified（163,181 状態）。head 照合を外した変異モデルで反例検出を確認 |
| 実リポジトリ (origin/main `a35988a`) の隔離品質検証 | **PASS**（7 チェック。npm-test 1953 pass / 0 fail / 4 skip。証跡 hash `980f35d0…`） |
| 同 初回（修正前） | FAIL: 27 件が `USER: unbound variable`（sandbox が USER を渡していなかった）→ 根本原因を修正し再実行 |
| 使い捨て PostgreSQL での 0001→0006 適用・射影・制約・ロールバック | PASS（DB は dropdb 済み） |
| Web コンソール（一時サーバ 3899・実データ） | 表示確認・Playwright E2E 10/10 |

### 隔離実行で skip になった 4 件（未検証として記録）

- formal（TLA+）2 件: sandbox の `$HOME` は tmpfs のため jar が見えなかった → `CCSU_FORMAL_CACHE` を ro で渡す修正を実装済み（再実測は未）。
- 残り 2 件は既存テスト側の環境依存 skip（ホスト実行でも skip 2 件）。

## 3. 未解決・残課題

1. ~~`/ship` の実機セッション検証~~ → 2026-11-24 17:42 に人が `/ship terms` を実行し成功（`SHIP_SESSION_VERIFICATION.md` §5）。実 PR での `/ship` と watch は未実施。
2. ~~gh 2.45.0 < 2.63~~ → 2026-11-24 に gh 2.105.0 へ更新済み（承認 #9）。
3. ~~PreToolUse(Bash) フックにより watch 不可~~ → PR #229 で解消。マージ後の capability は **overall=available / watch_possible=true**（2026-11-24 実測）。
4. Human Gate の施行（中央ポリシーは PR #185 で起案済み・未発効。ruleset・鍵登録・GitHub App は未）。
5. Actions 並走比較（10 PR）。
6. Playwright E2E の隔離実行（ブラウザが ro-root で動くか）— 未検証。

## 4. Phase 12 を実施できない理由

`/ship` は公式仕様で「人が入力した行」からのみ起動し（`claude -p` では `Nothing started` を実機確認）、
本リポジトリは gh 2.45 と PreToolUse(Bash) フックで watch が始まらない。AI が代行入力することは仕様・方針の両面で行わない。
代替として、本 PR の品質は Local Quality Engine・AI Quality Gate・独立テストで評価した（AI 自身の主観判定ではない）。

## 5. 次に行う作業

承認事項（完成報告書 §承認が必要な事項）への回答を受けてから、番号ごとに実施する。
