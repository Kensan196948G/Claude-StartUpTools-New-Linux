# Runtime Foundations — B 判定 13 項目の実装と検証

2026-09-25 時点の「最先端 AI 技術 45 項目」のうち、**この環境で自前実装可能（判定 B）**と
判定した 13 項目の実装・検証状況をまとめる。判定区分は次のとおり。

| 区分 | 意味 |
|---|---|
| A | このリポジトリで実装・稼働済み |
| **B** | **この環境で自前実装可能（設計〜検証まで）← 本ドキュメントの対象** |
| C | 実装は可能だが外部プロバイダ API 前提（組み込みのみ） |
| D | この環境では物理的に不可（学習基盤・物理アクチュエータ不在） |

## 実装一覧

| # | 項目 | 実装 | 主なテスト |
|---|---|---|---|
| 3 | Long-Horizon Agent | `lib/run-ledger.sh` + `bin/run-ledger.sh`（heartbeat / checkpoint / resume / finish） | `tests/bats/unit/run-ledger.bats` |
| 4 | Durable Agent Execution | 同上（`run.json` + `events.jsonl` に永続化、`reconcile` で中断検出） | `tests/bats/unit/run-ledger.bats` |
| 7 | Computer Use | `libexec/computer-use.sh`（probe / observe / plan / act） | `tests/bats/unit/computer-use.bats` |
| 21 | Multimodal Computer Use | 同上（画面取得 → プラン検証 → 1 ステップ実行。GUI がある環境でのみ発火） | `tests/bats/unit/computer-use.bats` |
| 29 | Synthetic Data | `scripts/tools/synth-data.js`（失敗履歴 / run / git 履歴 → 評価データセット、秘密スキャン付き） | `scripts/tools/synth-data.test.js` |
| 31 | Agentic SWE（大規模改修） | `bin/migration-run.sh`（worktree 分離 + group ごとの run 分割 + 検証証跡） | `tests/bats/unit/migration-run.bats` |
| 33 | Self-Healing Software | `bin/self-heal.sh`（ログ → 原因分類 → 修復提案。**propose-only**） | `tests/bats/unit/self-heal.bats` |
| 34 | Self-Improving Harness | `lib/improver-gate.sh` + `bin/improver-gate.sh`（fail-closed 昇格ゲート） | `tests/bats/unit/improver-gate.bats` |
| 36 | AI Scientist | `scripts/tools/evidence-ledger.js`（主張 → 出所 → 支持/反証 → 判断、出所の sha256 検証） | `scripts/tools/evidence-ledger.test.js` |
| 37 | AI + Formal Verification | `formal/specs/run_ledger.tla` + `scripts/tools/tla-check.sh`（TLC モデル検査） | `tests/bats/unit/formal-check.bats` |
| 40 | Private / Confidential AI | `bin/private-ai.sh` + `config/private-ai.json`（loopback + allowlist + 最小環境での子プロセス起動） | `tests/bats/unit/private-ai.bats` |
| 41 | Agent Identity / Policy Engine | `lib/policy-engine.sh` + `bin/policy-check.sh` + `config/agent-policy.json`（deny-by-default + 承認トークン） | `tests/bats/unit/policy-engine.bats` |
| 44 | Adversarial Agent Testing | `tests/adversarial/corpus.json` + `bin/adversarial-probe.sh`（自作ハーネス、期待判定との突き合わせ） | `tests/bats/unit/adversarial-probe.bats` |

## 設計上の一貫した方針

1. **deny-by-default**: ポリシーで分類されていない action は `risk=unknown` として拒否側に倒す
   （`lib/policy-engine.sh`）。`hard_deny` は承認トークンがあっても解除しない。
2. **fail-closed な昇格**: 改善の昇格は「証拠 / 回帰 eval / 改善者以外の承認」が揃わない限り通さない
   （`lib/improver-gate.sh`）。
3. **人間ゲートの明示**: 次は自動化しない。すべて「提案 + 人間の Y/N」で止める。
   - 33 Self-Healing の修正適用（propose-only、allowlist は空）
   - 31 大規模改修の統合（`report` は `mode=human_gated` を返し、`git push` までしか示さない）
   - 34 の main 反映 / 41 の権限変更 / Cloudflare の DNS・Access 変更
4. **「検証した」と言える範囲を限定する**: 外部 API 前提の項目（判定 C）と物理制約の項目（判定 D）は
   実装しない。GUI が無いホストでは computer-use は**拒否経路まで**を検証し、実行は「GUI がある環境で
   のみ可能」と明記する（下記「正直な限界」）。
5. **秘密を出力しない**: 監査ログ・実行ログ・データセットは本文ではなくハッシュ / メタ情報を残す
   （run-ledger の checkpoint は state-file の sha256 のみ、evidence-ledger は秘密パターンを拒否）。

## 検証の実測値（2026-09-25, このホスト）

```
$ bats tests/bats/unit/*.bats          # 全 unit テスト
$ node --test scripts/**/*.test.js     # Node 側テスト
$ bash bin/policy-check.sh matrix --json | jq -c '...'
{"allow":39,"approval_required":16,"deny":143}     # 実行時間 0.68s (198 判定)

$ bash bin/adversarial-probe.sh run
{"cases":18,"failed":0,...}

$ bash scripts/tools/tla-check.sh run --json | jq -c '{result,states_generated,distinct_states}'
{"result":"verified","states_generated":146,"distinct_states":60}
```

policy 判定の実行時間は、当初 198 判定に 2 分 23 秒かかっていた。原因は
`$(...)` とパイプラインが subshell を作るためメモ化が効かず、判定ごとに jq を何度も起動していたこと。
**設定 JSON を 1 回の jq 呼び出しで必要な値へ射影し、bash のグローバル変数に展開してから判定する**
方式へ変更した（区切り文字は GS/RS/US の 3 段を使い分ける）。結果は同一（39/16/143）で 0.68s。

## 正直な限界（この環境で「できない」こと）

| 項目 | 限界 |
|---|---|
| 7 / 21 Computer Use | このホストは headless（`DISPLAY`/`WAYLAND_DISPLAY` なし、`xdotool` 不在）。**観測・操作の実行は未検証**で、検証済みなのは「承認が無ければ撮らない」「allowlist 外の動詞を拒否する」「headless では実行しない」「既定は dry-run」という統制側。GUI セッションのある環境で `probe` → `observe` → `plan` → `act` を順に通す必要がある |
| 40 Private AI | 8B 級まで。**TEE / ハードウェア隔離は不可**（GPU は AMD 内蔵のみ、SGX/TDX 前提の構成は取れない）。Ollama は導入済みだが常時起動していないため、`private-ai.sh check` の `runnable` は通常 false（スタブでのテストのみ） |
| 33 Self-Healing | 原因分類と修復**提案**まで。自動適用は行わない（allowlist 空 + 承認必須をテストで固定） |
| 34 Self-Improving | 昇格**判定**まで。main への反映は人間の PR レビューが必須 |
| 37 形式検証 | 検証できたのは run-ledger の状態機械モデル 1 本（`TerminalStable` ほか）。**Lean 4 による数学的証明は未導入**（TLA+/TLC のみ）。仕様と bash 実装の対応は人手で維持する |
| 29 Synthetic Data | テキスト / コード / 履歴のみ。**画像・3D・センサデータの生成は不可**（生成モデルの学習基盤が無い） |
| 36 AI Scientist | 「主張 → 出所 → 支持/反証」の追跡まで。仮説の**自動生成や解析の自動実行はしない**（判断は人またはモデルが与える） |
| 4 Durable Execution | Ctrl-C 相当の中断からの再開は検証済み。**クラッシュ整合性（電源断など）は保証範囲外** |
| 3 Long-Horizon | heartbeat TTL と reconcile による「止まった run の検出」まで。数日規模の連続実行はクラウド API の可用性に依存 |

## 次に効く順（未実施）

1. `feat/control-plane-pr*`（PR#1〜#10）の main 統合 — 判定 A が 13 → 16 に増える（人間判断）
2. eval カバレッジ拡張 — golden eval は現在 `scripts/tools/agent-router.js` のみ
   （`docs/architecture/SELF_IMPROVEMENT_ARCHITECTURE.md:43` の規約に従い、改善対象ごとに golden を追加）
3. GUI セッション上での computer-use 実機検証（7 / 21 を「統制済み」から「実働」へ）
