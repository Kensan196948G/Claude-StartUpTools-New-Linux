# 横断是正の判断材料（2026-11-23 実測）

状態: **読み取り専用の分析**。この文書は是正を実行しない。何を・どの順で・誰の承認でやるかを決めるための材料。

- 対象: `Kensan196948G` 配下の全リポジトリ
- 実測: 2026-11-23 12:36〜12:50 JST（`bin/repo-integration-status.sh --classify --json --limit 100`）
- 前提: 判定は GitHub 側の実データ（rulesets / pulls / contents）のみ。リポジトリ内の設定ファイルの記載は根拠にしない
- 出典: 連携監査 task-2（2026-11-23）→ `bin/repo-integration-status.sh`（#191）→ 本分類（task-20）

## 1. 再現方法

```bash
# 全量（約3.5分・API 約250回）
bin/repo-integration-status.sh --classify --json --limit 100

# 一部だけ（約1分）
bin/repo-integration-status.sh --classify --json --limit 20
```

`--json` の最終行が機械可読サマリ。`--classify` を付けると `pr_types` / `age_buckets` / `prs` / `ci_presence` が加わる。
`unknown` は「ruleset か open PR を判定できなかった repo 数」で、**「ruleset なし」とは別物**。

## 2. 実測値

| 指標 | 値 | 補足 |
|---|---|---|
| 走査 repo 数 | 76 | `--limit 100` で全件 |
| ruleset なし | 21 | `central-auto-merge` が無い repo |
| 別名 ruleset | 5 | main-protection 4 / main-required-checks 1 |
| open PR | 210 | 実行時点。増減する |
| CLEAN+green | **33** | required checks 通過・非 draft・失敗チェック 0 なのに未マージ |
| unknown | 0 | 判定不能は今回ゼロ |

> 注意: 33 は「CI が緑で、技術的にはいつでもマージできるのに放置されている」PR。CI が赤い PR は含まない（それは別問題）。

## 3. 滞留 PR 33 件の内訳

### 3.1 種別

| 種別 | 件数 | 判定基準 |
|---|---|---|
| deps | **22** | dependabot / renovate / "bump" / `(deps)` を含む |
| docs | 3 | `docs` で始まる |
| feat | 0 | `feat` で始まる |
| fix | **4** | `fix` で始まる |
| chore | 0 | `chore` で始まる |
| unknown | 4 | 上記以外 |

→ **依存更新が 67%（22/33）**。機能追加は 0 件で、**実際のバグ修正が 4 件**混ざっている。

### 3.2 経過日数

| バケット | 件数 | 定義 |
|---|---|---|
| <7 日 | 14 | 直近。正常範囲とも読める |
| 7-30 日 | 4 | |
| 30-90 日 | 11 | 明確な滞留 |
| >90 日 | 4 | 事実上の放置 |

30 日超は計 15 件。

### 3.3 種別 × 経過

| 種別 | <7 | 7-30 | 30-90 | >90 |
|---|---|---|---|---|
| deps | 6 | 2 | 10 | 4 |
| docs | 3 | 0 | 0 | 0 |
| fix | 1 | 2 | 1 | 0 |
| unknown | 4 | 0 | 0 | 0 |

### 3.4 repo 別（3 件以上）

| repo | 件数 | 主な種別 |
|---|---|---|
| Software-Factory | 6 | deps 5 / docs 1 |
| Construction-DX-Idea | 4 | deps 4（すべて 77 日） |
| dd-e2e-sandbox | 4 | unknown 4（sandbox smoke） |
| Civil-IT-Operation-Enterprised-Platform | 3 | deps 3（すべて 103 日） |
| CivilPDF-Editor | 3 | deps 3（84〜98 日） |
| Construction-Logistics-Route-Planner | 3 | deps 3（28〜41 日） |

### 3.5 30 日超の全 15 件

| 経過 | PR | 種別 |
|---|---|---|
| 103d | Civil-IT-Operation-Enterprised-Platform #162 / #163 / #164 | deps |
| 98d | CivilPDF-Editor #114 | deps |
| 84d | CivilPDF-Editor #126 / #128 | deps |
| 77d | Construction-DX-Idea #81 / #83 / #84 / #85 | deps |
| 55d | Construction-LegalOps-DX #134 | **fix** |
| 49d | Mirai-AI-Agent-Business-Platform #55 | deps |
| 41d | Construction-Logistics-Route-Planner #34 / #35 | deps |
| 33d | Civil-Cost-Index-Dashboard #94 | deps |

**最優先は 55 日滞留の `fix`（Construction-LegalOps-DX #134: native stack 障害の Root Cause 4 件修正）**。依存更新 1 件より影響が大きい。

## 4. ruleset なし 21 repo の CI 有無

`ruleset を当てると required check の通過が必須になる`。CI が無い repo に当てると **全 PR が永久にマージ不可**になるため、適用可否は CI の有無で決める。

| 区分 | 件数 | 扱い |
|---|---|---|
| CI あり | **16** | ② ruleset 適用の候補 |
| CI なし | **5** | ① 先に CI 整備（または対象外判断） |
| unknown | 0 | 今回はゼロ |

CI なし 5 repo:

| repo | 備考 |
|---|---|
| Cybersecurity-Sovereign-AgentOS | |
| Construction-Public-Twin-Portal | |
| Server-Disk-Management | |
| BLB-Safe-Renamer | |
| Codex-StartUpTools | ツール repo。`config/config.json` の `localExcludes` で製品対象外と同種の扱い。ruleset 対象外の判断もあり |

## 5. 推奨手順（4 段階・この順で行う）

順序に意味がある。②を①より先にやると PR が止まる。

### ① CI 整備 — 対象 5 repo

- やること: 最小 CI（lint か secret scan を 1 本）を追加し、PR で 1 回報告されることを確認する。
- 代替案: `Codex-StartUpTools` はツール repo なので、CI を足さずに **ruleset 対象外**とする判断でもよい。
- 完了条件: 対象 repo の PR で check 名が 1 つ以上報告される。

### ② ruleset 適用 — 対象 16 repo（CI あり）

- やること: `central-auto-merge`（strict=true, bypass_actors 空, squash のみ）を既定ブランチへ適用。
- **適用前に必ず**: 1 本の PR で実際に報告される check 名を確認し、`required_status_checks` に登録する名前と突合する。名前がずれると永久 pending になる（本リポジトリでは一致を確認済み）。
- 完了条件: 対象 repo で「赤 CI の PR が BLOCKED になる」ことを 1 件で確認。

### ③ 滞留 PR 処理 — 33 件

| 区分 | 件数 | 推奨 |
|---|---|---|
| deps（メジャー bump） | 8 | 個別確認。パッケージ 5 件（eslint 9→10 / typescript 5.9→7 / vite 7→8 / jose 5→6 / @vitejs/plugin-react 4→5）＋ GitHub Actions 3 件（setup-node 4→7 / upload-artifact 4→7 / setup-python 5→7） |
| deps（マイナー・パッチ） | 14 | CI 緑なら一括マージ候補 |
| docs | 3 | 中身を確認してマージ |
| fix | 4 | **最優先で個別に処理**（#134 は 55 日滞留） |
| unknown（dd-e2e-sandbox の sandbox smoke） | 4 | クローズ可（テスト用 repo） |

- 30 日超の 15 件は「一度も人が見ていない」可能性が高いので、マージより先に**1 件ずつ差分を確認**する。
- 一括操作をするとしても、まず `fix` 4 件と `deps` のメジャー 6 件を除外してから。

### ④ controller 定常化

- 現状: auto-merge を arm する実行体が無い（`bin/github-controller.sh` は存在しない、`bin/github-pr-flow.sh` は判定のみ）。CLEAN+green が 33 件溜まるのはこのため。
- やること（案）:
  1. 本ツールを定期実行して可視化を続ける（cron / workflow）。
  2. auto-merge 登録を自動化するか、人間マージのままにするかを方針決定する（中央ポリシー §5 手順 8）。
- どちらも**ポリシー変更**なので人間の承認が要る。

## 6. リスク

| # | リスク | 影響 | 回避 |
|---|---|---|---|
| R1 | CI なし repo に ruleset を先行適用 | 全 PR が永久にマージ不可（fail closed） | ①を先に完了させる |
| R2 | required check 名の不一致 | 永久 pending | 適用前に 1 PR で実報告名を突合 |
| R3 | deps の一括マージ | メジャー bump の破壊的変更が混入 | メジャー 8 件を除外して個別確認 |
| R4 | 33 件の一括クローズ | 必要な修正（fix 4 件）を失う | fix を先に退避して処理 |
| R5 | 本ツールの API 消費 | 76 repo で約 250 呼び出し | `--limit` で分割、短期間に連打しない |

## 7. 人間の承認が必要な点

1. 16 repo への ruleset 新規適用（対象範囲を広げる判断）
2. 33 PR のマージ・クローズ（不可逆）
3. 中央ポリシー本文の変更（§5 手順 8・§6）
4. `Codex-StartUpTools` を ruleset 対象外とするか
5. ①で追加する CI の内容（各 repo の品質基準に関わる）

## 8. 未確認

- 33 件が未マージの理由（人の判断か放置か）の意思決定ログ
- CI あり 16 repo のうち、PR で実際に走る workflow かどうか（`pull_request` トリガの有無までは未検証）
- 16 repo の required check 名が実報告名と一致するか（突合は未実施）
- auto-merge が過去に一度でも発火したか（履歴 API では判別不能）
- `ci_presence` は `.github/workflows` の**存在**を見ている。ワークフローはあるが CI が走らない repo は「CI あり」に数えられる
