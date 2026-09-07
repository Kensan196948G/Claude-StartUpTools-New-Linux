# Agent Catalog (ClaudeOS v10 Lazy Agent Architecture)

正本: `config/agent-catalog.json`。first-class だけを `.claude/agents` へ配布し (context 常時ロードは 9 体分の description のみ)、それ以外は必要時に本文を Read して Agent tool の prompt に渡す。削除ではなく deprecated として保持し、Self-Improvement サイクルで整理する。

| agent | 区分 | 目的 / 統合先 / 理由 | ロード方法 |
|---|---|---|---|
| `cto` | first-class | 統括・優先順位・Phase Gate・リリース判定 | .claude/agents (auto-discovery) |
| `manager` | first-class | Issue 生成 / GitHub Projects 遷移 | .claude/agents (auto-discovery) |
| `code-reviewer` | first-class | 汎用コードレビュー (言語別 rubric は skills で付与) | .claude/agents (auto-discovery) |
| `security-reviewer` | first-class | secret / 権限 / 依存関係 / 脆弱性の独立レビュー (Verify・Release ゲート) | .claude/agents (auto-discovery) |
| `ci-manager` | first-class | CI 失敗の原因分析と最小差分修復 | .claude/agents (auto-discovery) |
| `outcome-grader` | first-class | STABLE rubric による独立判定 (Generator / Verifier 分離) | .claude/agents (auto-discovery) |
| `e2e-runner` | first-class | E2E 実行と回帰確認 | .claude/agents (auto-discovery) |
| `audit-agent` | first-class | 変更証跡・規格準拠 (Verify 末尾 / Release 前) | .claude/agents (auto-discovery) |
| `cmdb-agent` | first-class | 構成アイテム・依存関係・変更影響 (Monitor 末尾) | .claude/agents (auto-discovery) |
| `api-designer` | catalog | API 境界設計時。dev-api を吸収 | Read on demand / Agent prompt に本文を渡す |
| `architect` | catalog | アーキテクチャ・DB・auth 境界の重要判断 | Read on demand / Agent prompt に本文を渡す |
| `build-error-resolver` | catalog | ビルド失敗時 (言語別 resolver 6 体を吸収) | Read on demand / Agent prompt に本文を渡す |
| `database-reviewer` | catalog | schema / migration / index レビュー | Read on demand / Agent prompt に本文を渡す |
| `doc-updater` | catalog | README / 設計書 / runbook 更新 | Read on demand / Agent prompt に本文を渡す |
| `performance-reviewer` | catalog | 性能観点のレビュー | Read on demand / Agent prompt に本文を渡す |
| `qa` | catalog | テストマトリクス・回帰 (tester を吸収) | Read on demand / Agent prompt に本文を渡す |
| `release-manager` | catalog | リリース手順・rollback (ops を吸収) | Read on demand / Agent prompt に本文を渡す |
| `tdd-guide` | catalog | TDD 進行の伴走 | Read on demand / Agent prompt に本文を渡す |
| `cpp-reviewer` | merge → code-reviewer | C++ コードの設計、所有権、例外安全、ビルド構成、保守性を確認するレビュー担当。 | deprecated (次回整理) |
| `go-reviewer` | merge → code-reviewer | Go の idiom、並行処理、安全性、インターフェース設計をレビューする担当。 | deprecated (次回整理) |
| `java-reviewer` | merge → code-reviewer | Java と Spring Boot の設計、例外処理、トランザクション、保守性を確認する担当。 | deprecated (次回整理) |
| `kotlin-reviewer` | merge → code-reviewer | Kotlin、Android、KMP の設計、null 安全性、非同期処理をレビューする担当。 | deprecated (次回整理) |
| `python-reviewer` | merge → code-reviewer | Python の型、例外処理、責務分割、pytest との整合をレビューする担当。 | deprecated (次回整理) |
| `rust-reviewer` | merge → code-reviewer | Rust の所有権、借用、非同期、安全性、モジュール設計をレビューする担当。 | deprecated (次回整理) |
| `typescript-reviewer` | merge → code-reviewer | TypeScript と JavaScript の型安全性、React/Next.js 設計、保守性をレビューする担当。 | deprecated (次回整理) |
| `cpp-build-resolver` | merge → build-error-resolver | C++ のコンパイルエラー、リンクエラー、ABI 差異、CMake 設定不備を解消する担当。 | deprecated (次回整理) |
| `go-build-resolver` | merge → build-error-resolver | Go の build、test、module、toolchain、依存不整合を修復する担当。 | deprecated (次回整理) |
| `java-build-resolver` | merge → build-error-resolver | Java、Maven、Gradle、Spring Boot のビルド失敗を切り分けて修復する担当。 | deprecated (次回整理) |
| `kotlin-build-resolver` | merge → build-error-resolver | Kotlin と Gradle の依存、Android build、KMP 設定不整合を解消する担当。 | deprecated (次回整理) |
| `pytorch-build-resolver` | merge → build-error-resolver | PyTorch、CUDA、学習ループ、依存環境、GPU メモリエラーを切り分ける担当。 | deprecated (次回整理) |
| `rust-build-resolver` | merge → build-error-resolver | Rust のコンパイルエラー、trait 不一致、Cargo 設定問題を解決する担当。 | deprecated (次回整理) |
| `dev-api` | merge → api-designer | バックエンド実装担当。API設計・実装・DB設計・ビジネスロジック実装・バグ修正を行う。 | deprecated (次回整理) |
| `tester` | merge → qa | テスト実行・CI連携担当。自動テスト実行・CIログ解析・テスト結果収集を行う。 | deprecated (次回整理) |
| `ops` | merge → release-manager | インフラ・デプロイ管理担当。STABLE判定後のdeploy実行、環境管理、障害検知を行う。 | deprecated (次回整理) |
| `loop-operator` | merge → cto | Monitor、Build、Verify、Improve の自律ループを運用し、止めどきと再開点を管理する担当。 | deprecated (次回整理) |
| `orchestrator` | merge → cto | Agent Teams全体を調整し、Monitor→Build→Verify→Improveのループを制御するオーケストレーター。STABL | deprecated (次回整理) |
| `planner` | remove-candidate | native Plan subagent / plan mode | deprecated (native 代替) |
| `docs-lookup` | remove-candidate | native Explore subagent / claude-code-guide | deprecated (native 代替) |
| `refactor-cleaner` | remove-candidate | native /simplify | deprecated (native 代替) |
| `chief-of-staff` | remove-candidate | 役割重複 (cto / manager) | deprecated (native 代替) |
| `dev-ui` | remove-candidate | 役割重複 (frontend は skills で表現) | deprecated (native 代替) |
| `harness-optimizer` | remove-candidate | Self-Improvement (Improver skill) へ統合 | deprecated (native 代替) |
| `incident-triager` | remove-candidate | Linux Operations (bin/incident-response.sh) と重複 | deprecated (native 代替) |

合計 43 体 (first-class 9 / catalog 9 / merge 18 / remove-candidate 7)
