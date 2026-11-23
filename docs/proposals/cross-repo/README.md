# 横断是正 段階①: CI なし repo の最小 CI 提案（2026-11-23）

状態: **提案のみ**。他リポジトリへの書き込み・PR 作成・ruleset 変更は行っていない。
このディレクトリの YAML は「Y が出たら、そのまま対象 repo の `.github/workflows/ci.yml` として PR する」ための雛形。

- 入力: `bin/cross-repo-remediate.sh --plan`（#203）の段階①対象 5 repo と、段階②の `needs_manual_check_names` 3 repo
- 調査: `gh api repos/{o}/{r}/contents`, `/languages`, `git/trees`, 各ファイル本体を**読み取りのみ**で確認
- **緑になることの検証**: 各コマンドを実ファイルに対して実行して確認した（§4）。推測で書いたコマンドは無い。

## 1. 対象 repo と採用コマンド

すべて **job 名（= 必須チェック名）は `ci`** に統一した。ruleset の `required_status_checks` には `ci` を入れる。

| repo | 検出した言語・構成 | 採用コマンド（実在確認済み） | 不採用 |
|---|---|---|---|
| Cybersecurity-Sovereign-AgentOS | HTML/JS。package.json 無し。`tests/*.test.cjs` は `node:test`、`scripts/verify-local.cjs` | `node --check scripts/verify-local.cjs`<br>（テストは §4 の理由で保留） | `node --test`（現状 7 件失敗のため） |
| Construction-Public-Twin-Portal | TS/Next 16。package-lock.json / eslint.config.mjs / vitest.config.ts / tsconfig.json | `npm ci`<br>`npm run lint`（eslint .）<br>`npm run typecheck`（tsc --noEmit）<br>`npm run test`（vitest run） | `npm run build`（先頭で `scripts/copy-cesium.mjs` を実行し vendor 済み資産に依存するため） |
| Server-Disk-Management | PowerShell/Batch/HTML。テスト・マニフェスト無し | `Parser::ParseFile` による .ps1 構文検査のみ | PSScriptAnalyzer（追加導入が要る）、.bat（ランナーで静的検査不可） |
| BLB-Safe-Renamer | PowerShell/JS/Batch。テスト・マニフェスト無し | `node --check scripts/tools/run-ultrareview.js`<br>`Parser::ParseFile` による .ps1 構文検査 | .bat（同上） |
| Codex-StartUpTools | Shell 88 KB。Makefile に syntax/lint/test/verify | `make syntax`<br>`make lint`（shellcheck）<br>`make test`（tests/run_tests.sh は bash のみ） | — |

テストが無い 2 repo（Server-Disk-Management / BLB-Safe-Renamer）は、指示どおり **構文検査のみ**にした。
存在しないテストコマンドを書かないことを優先している。

### トリガを `on: [push, pull_request]` にした理由（重要）

`pull_request` だけにすると、**既定ブランチに check-run が残らず**、ruleset 適用前の下調べで
「CI が無い」と誤判定される。実際に Software-Factory-Sandbox がこの形で誤判定された（§3）。
そのため提案は全 repo で push でも走らせる。既定ブランチ名に依存しない利点もある
（Cybersecurity-Sovereign-AgentOS の既定ブランチは `main` ではなく `auto/baseline-preservation`）。

## 2. 適用手順（Y が出た後の順序）

順序を変えると PR が止まる。**CI を先、ruleset を後**。

1. 対象 repo に `docs/proposals/cross-repo/<repo>.ci.yml` を `.github/workflows/ci.yml` として置く PR を作る
2. その PR で **`ci` という check が実際に報告され、緑になる**ことを確認する
   - 名前が違うと、次の ruleset で永久 pending になる（既知のリスク R2）
3. `ci` を `required_status_checks` に入れた ruleset `central-auto-merge` を適用する
   （POST ボディは `bin/cross-repo-remediate.sh --plan` の `stage2_ruleset.bodies` を使う）
4. 別の PR で「赤い CI が BLOCKED になる」ことを 1 件確認する

Codex-StartUpTools は **対象外**にする選択肢もある。ツール repo であり製品ではないためで、
`config/config.json` の `localExcludes` が同じ repo を除外している扱いと整合する。
その場合は 1〜4 を行わない。

## 3. `needs_manual_check_names` 3 件の対処案（実測で再分類）

#203 の plan は「既定ブランチの check-run が 0 件」を理由にこの 3 件を手動確認へ回した。
実測で中身を確認したところ、**3 件の性質はそれぞれ違う**。

| repo | 実測した中身 | 判定 | 対処案 |
|---|---|---|---|
| **SiteLive-Twin** | `.github/workflows/` の中身は **`.gitkeep`（0 B）だけ**。workflow は存在しない | **CI なし**（段階①に移す） | 最小 CI を追加する。ただし言語・構成が未調査なので、追加前に確認が要る |
| **Software-Factory-Sandbox** | `ci.yml` は **`on: pull_request` のみ**。job 名は `static`。PR では実際に走っている（直近 3 run = success/failure/success） | **適用可能**（手動確認不要） | 必須チェック名は **`static`**。main に check-run が無いのは push トリガが無いため |
| **open-design** | `nexu-io/open-design` の **fork**。workflow 51 本。最終 push 2026-09-25。main に check-run なし | **対象外を推奨** | 上流 fork であり自社製品ではない。51 本を自社 CI として維持する理由がない |

再分類で母数はこう変わる。

| 区分 | #203 の plan | 今回の再分類 |
|---|---|---|
| 段階①（CI なし） | 5 | **6**（+ SiteLive-Twin） |
| 段階② 生成可能 | 13 | **14**（+ Software-Factory-Sandbox、check 名 `static`） |
| 段階② needs_manual | 3 | **0** |
| 対象外 | 0 | **1**（open-design） |

**この 2 件の誤判定は、`bin/repo-integration-status.sh` の CI 判定が
「`.github/workflows` の存在」と「既定ブランチの check-run」だけを見ていることに起因する。**
ツール側の改善候補（本 PR の範囲外）:
- `.github/workflows` の中身が `.gitkeep` だけなら「CI なし」と判定する
- check-run が 0 件のとき、`pull_request` トリガの workflow があれば job 名を拾って「適用可能」に寄せる

## 4. 各コマンドの実測結果（緑になるか）

実ファイルを取得して、提案と同じコマンドを実行した結果。

| repo | 実行した確認 | 結果 |
|---|---|---|
| Cybersecurity-Sovereign-AgentOS | `node --check scripts/verify-local.cjs` | **PASS**（CI に採用） |
| 〃 | `node --test tests/*.test.cjs` | **82 件中 75 pass / 7 fail** → 採用せず保留 |
| 〃 | `node --test tests/` | **MODULE_NOT_FOUND**（Node 22 はディレクトリ引数を解釈しない） |
| Server-Disk-Management | `Parser::ParseFile(Disk-Management.ps1)` | **PASS**（tokens=5361） |
| BLB-Safe-Renamer | `Parser::ParseFile(Rename-BlbSafe.ps1)` / `node --check scripts/tools/run-ultrareview.js` | **PASS**（tokens=1166） |
| Codex-StartUpTools | `bash -n bin/*.sh lib/*.sh tests/run_tests.sh`（make syntax 相当） | **PASS** |
| 〃 | `shellcheck bin/*.sh lib/*.sh tests/run_tests.sh`（make lint 相当） | **PASS**（exit 0） |
| 〃 | `./tests/run_tests.sh`（make test 相当） | **PASS**（全 ok） |
| Construction-Public-Twin-Portal | `npm ci` 以降は未実行 | **未検証**（オフラインで npm install できないため） |

Cybersecurity の失敗 7 件はすべて `sample-app.test.cjs`（キルスイッチ再評価・本番昇格拒否・
Manifest 型検証・保存状態検証など）。**テストの期待とアプリ実装が一致していない**ので、
CI を赤のまま入れず、7 件を解消してからテスト step を有効化する方針にした。

Codex-StartUpTools の `make test` は、`gh api` で取得したファイルに実行ビットが無いと
`Permission denied` になる（実測）。git 上は `100755` なので `actions/checkout` では問題ない。

## 5. YAML の検証

```bash
python3 - <<'PY'
import glob, yaml
for p in sorted(glob.glob("docs/proposals/cross-repo/*.ci.yml")):
    with open(p, encoding="utf-8") as f:
        d = yaml.safe_load(f)
    assert d["jobs"]["ci"]["name"] == "ci", p
    print("ok", p, "steps=", len(d["jobs"]["ci"]["steps"]))
PY
```

## 6. 未確認

- Construction-Public-Twin-Portal の `npm ci` / `npm run lint` / `typecheck` / `test` は**未実行**。
  特に `npm run test`（vitest）が DB を要さないかは、`db/` と `@types/pg` があるため要注意
- Software-Factory-Sandbox の `static` が**必須チェックとして安定して報告され続けるか**（PR の 3 run しか見ていない）
- Server-Disk-Management / BLB-Safe-Renamer の `.bat` は静的検査の対象外（ランナー手段なし）
- SiteLive-Twin の言語・構成（CI を書く前に別途調査が必要）
- Cybersecurity の失敗 7 件が「テストが古い」のか「実装が退行している」のかは未判定
