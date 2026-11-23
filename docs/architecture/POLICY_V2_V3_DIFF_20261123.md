# 中央 GitHub ポリシー v2 → v3 差分と本リポジトリへの影響

- 作成: 2026-11-23 / 担当: release-auditor（task-21）
- 対象: 中央 `GITHUB_POLICY.md`（v3, 2026-10-05 発効）と本リポジトリの `GITHUB_POLICY.md`（v2）の差分
- 立場: **分析のみ。ポリシーは変更しない**（v3 §8「本ポリシー自体の変更」は人間ゲート）
- 根拠の示し方: すべて「ファイル:行」「コマンド」「終了コード/実測値」を付す。推測は「推測」と明記する。

---

## 0. 結論（TL;DR）

1. **v3 は v2 の純粋な上位互換である。** 差分は 3 箇所のみ（ヘッダ状態行 / §3 の注意書き 2 行 / §10 の新設 42 行）。§1・§2・§4・§5・§6・§7・§8 の本文は md5 一致、§9 も本文一致（末尾境界のみ差）。
2. **v3 が追加した「除外条項」は条件ベースではなくリポジトリ限定である。** 対象は `mirai-construction-dx/Mirai-Platform-Infra` **のみ**（§10）。本リポジトリは対象外であり、§10 による緩和も制約も受けない。
3. **本リポジトリの現運用（PR #171〜#192 を Required Checks PASS 後に squash merge）は v3 でも許容される。** 22/22 PR が全チェック SUCCESS、22/22 が人間（Kensan196948G）による squash（親 1 個）、merge 後に branch 削除済み。v3 §4.6 / §4.8 / §4.9 を満たす。
4. ただし本リポジトリの**正本は中央**と明記されている（`AGENTS.md:30`、`docs/architecture/GitHub開発運用仕様.md:4`）。したがって **v3 は既に本リポジトリを拘束しており**、ローカル v2 コピーは stale mirror である。同仕様書の「本リポジトリのコピーは同一内容」という記述は現在**虚偽**（v2 7511B と v3 10552B は不一致）。
5. **推奨は案 A（v3 追随）＋参照 3 件の書き換え＋ヘッダへの版/正本の明記**。案 B（中央で v3 を戻す）は人間承認済みの他リポジトリ例外を巻き戻すため非推奨。**決定は人間**。

---

## 1. 測定条件

| 項目 | 値 | 根拠 |
|---|---|---|
| 本リポジトリ（v2） | 7511 bytes / 150 行 / md5 `f6038007e79102c3699da97899ef8cab` | `stat -c %s` / `wc -l` / `md5sum` |
| 中央（v3） | 10552 bytes / 195 行 / mtime 2026-10-07 20:02 | 同上 |
| 差分 | 3 hunk / +46 行 / -1 行（net +45 行, +3041 bytes） | `diff -u A B` → `grep -c '^+'` 等 |
| 本リポジトリの v2 は無改変か | 他リポジトリの v2 配布 2 本と **md5 一致**（`Mirai-Project/Mirai-Info`, `Mirai-Project/PC-Ops-Orchestrator`） | `md5sum` 3 ファイル |
| 節の同一性判定 | `## ` 境界で本文を切り出し md5 比較 + `diff -u` の hunk 位置 | 付録 §10.2 |

**版の分布（参考・読み取りのみ）**: `~/Projects` 配下（maxdepth 3, worktree/archive 含む）で `GITHUB_POLICY.md` は v1(4750B)=59 / v2(7511B)=48 / v3(10552B)=13 / 版不明(5407B, ヘッダ v1・9 節・auto-merge 記述あり)=6。
※ task-21 の背景にある「v1×3 / v2×5 / v3×1」は配布台帳スコープの数値であり、本測定の分母（ローカル全体）とは異なる。**台帳スコープの再測定はしていない（未確認）**。

---

## 2. 節単位の差分

| 節 | v2 | v3 | 差分 |
|---|---|---|---|
| ヘッダ「状態:」 | 行 3（v2 発効まで） | 行 3（**v3 発効を追記**） | 変更 |
| §1 目的 | 行 5-8 | 行 5-8 | なし（本文 md5 一致） |
| §2 適用範囲 | 行 10-14 | 行 10-14 | なし（本文 md5 一致） |
| §3 優先順位（権限の正本） | 行 16-37 | 行 16-39 | **追加 2 行**（Repo 限定適用除外の注意書き） |
| §4 GitHub運用ルール | 行 39-54 | 行 41-56 | なし（本文 md5 一致） |
| §5 GitHub Controller の責務 | 行 56-75 | 行 58-77 | なし（本文 md5 一致） |
| §6 GitHub側の必須設定 | 行 77-120 | 行 79-122 | なし（本文 md5 一致） |
| §7 現状（2026-08-15 実測） | 行 122-134 | 行 124-136 | なし（本文 md5 一致） |
| §8 人間が残す判断 | 行 136-145 | 行 138-147 | なし（本文 md5 一致） |
| §9 詳細仕様 | 行 147-150 | 行 149-152 | なし（本文一致。境界の末尾空行でハッシュのみ差） |
| §10 適用除外（Repo限定・2026-10-05 v3） | — | 行 154-195 | **新規 42 行** |

### 2.1 ヘッダの差分（逐語）

v2（`GITHUB_POLICY.md:3`）:

```
状態: 2026-08-15 制定（v1）／2026-09-30 v2 発効（全リポジトリ auto-merge 統一。Approval #71 でユーザーが Y と承認。`docs/architecture/全リポジトリAutoMerge統一方針.md`）
```

v3（中央 `GITHUB_POLICY.md:3`）— 末尾に追記:

```
／2026-10-05 v3 発効（§10 に Repo限定の適用除外を追加。対象は `mirai-construction-dx/Mirai-Platform-Infra` のみ。ユーザーが Y と承認）
```

### 2.2 §3 の差分（逐語・追加 2 行）

v3 は §3 の表（無視される例）と「一方、次は常に尊重する。」の**間**に次を挿入する（中央 `GITHUB_POLICY.md:33`）:

```
> **Repo限定の適用除外**: §10 に記載した適用除外は、本ポリシー本文（§8「本ポリシー自体の変更」の人間承認）に基づく限定であり、Workspace側の記述による上書きではない。上表は §10 の対象リポジトリにおける除外範囲を除き、引き続き有効である。
```

読み方: 表の「Workspace の記述は無視される」は維持される。§10 は Workspace 側の自己申告ではなく、**ポリシー本文の限定**としてのみ成立する。本リポジトリが §10 を根拠に何かを免除されることはない（そもそも対象外）。

---

## 3. §10 の逐語引用（新規セクション全文）

中央 `GITHUB_POLICY.md:154-195`:

```
## 10. 適用除外（Repo限定・2026-10-05 v3）

本ポリシー本文に基づき、次の1リポジトリに限り §5・§6 の一部を適用除外する。
これは Workspace 側の記述による上書きではなく、**本ポリシーの限定として**記録する（§8「本ポリシー自体の変更」に基づく人間の承認済み）。

### 対象

- `mirai-construction-dx/Mirai-Platform-Infra` **のみ**。他リポジトリへ拡大しない。

### 適用除外する条項

- §5 手順8「Auto-Merge登録（`gh pr merge --auto --squash`）」
- §6 Repository settings「`Allow auto-merge`: ON」

§6 の他の設定（`Delete branch on merge`: ON、Default merge method: Squash）は維持する。

### 代わりに適用する方式（人間ゲート）

1. Bot は、機械的合格判定ができた場合**のみ**自動 Approve する（これはマージ判断ではない）。
2. 最終マージ Y/N は**人間**が判断する。Y は対象 head SHA に固定する。
3. Y を受けた側は、条件（承認時 SHA・checks・PR状態）が変わっていないことを再確認してから、**その1回だけ**マージする。
4. 既マージ・SHA変更・PR非OPEN は Fail Closed で拒否する。AI（エージェント）は merge せず、Y の代理投稿もしない。

正本実装: `Construction-World-Model-Platform/01_construction-world-model-management` の
`decisions/ADR-0011-bot-approve-and-single-merge.md`・`scripts/mergegate.py`・`.github/workflows/merge-gate.yml`。

### 施行条件

- 本除外は、対象リポジトリで上記方式が**実装・設定された後**に適用する。
- 実装完了までは auto-merge を有効化しない（Fail Closed）。
- 設定変更（`Allow auto-merge`: OFF、`Allow GitHub Actions to create and approve pull requests`: ON）は **owner が行い**、AI は readback のみ行う。

### 維持される統制

- Required Checks は引き続き必須（対象リポジトリでは `contracts`・`CodeRabbit`）。
- §8「人間が残す判断」（Release / 本番deploy / Secret / 不可逆な削除・破壊的操作 / 本ポリシー変更）は維持。
- main直接push禁止、`gh pr merge --admin` による迂回禁止、force push禁止、main削除禁止は維持。

### 承認根拠

- 2026-10-05、ユーザー（Kensan196948G）が本適用除外を Y と承認。
- 本記録はチャット上の承認を転記したものであり、GitHub本人性の新しい証明ではない。
```

---

## 4. v3 の「除外条項」の列挙

v3 が追加した除外は**条件ベース（例: 依存更新 PR は対象外、docs-only は対象外）ではなく、リポジトリ限定**である。列挙すると次の 2 条項のみ。

| # | 除外される条項 | 効果 | 対象 |
|---|---|---|---|
| E1 | §5 手順 8「Auto-Merge登録（`gh pr merge --auto --squash`）」 | Controller は auto-merge を登録しない | `mirai-construction-dx/Mirai-Platform-Infra` **のみ** |
| E2 | §6 Repository settings「`Allow auto-merge`: ON」 | 同リポジトリでは auto-merge を有効化しない（OFF 前提） | 同上 |

維持されるもの（§10 末尾）: §6 の `Delete branch on merge`: ON、Default merge method: Squash、Required Checks、§8 の人間ゲート、main 直 push 禁止、`--admin` 迂回禁止、force push 禁止、main 削除禁止。

**本リポジトリへの適用可否**: E1/E2 のいずれも対象外（`§10 対象: …のみ。他リポジトリへ拡大しない`）。したがって v3 は本リポジトリに対して **v2 と同じ義務**を課す。

---

## 5. 現運用が v3 で許容されるかの判定

### 5.1 判定: **許容される（v3 で新たな違反は生じない）**

| v3 の要求 | 本リポジトリの実測 | 判定 |
|---|---|---|
| §4.2 すべての変更は branch + PR | PR #171〜#192 は全て `auto/<slug>` branch 由来 | 充足 |
| §4.4 Conventional Commits | merge commit 件名が `feat(...)`/`fix(...)`/`docs(...)`/`test(...)` 形式（例 `b0e4c4c docs(architecture): … (#192)`） | 充足 |
| §4.6 Required Checks 全 PASS まで merge しない | 22/22 PR で `statusCheckRollup` の conclusion が全て `SUCCESS`（終了状態） | 充足 |
| §4.8 Squash Merge に統一 | 22/22 が squash（代表検証: `b0e4c4c` の親は 1 個、件名末尾 `(#192)`） | 充足 |
| §4.9 merge 後に branch 自動削除 | 例: `auto/batch3-docs` は remote に 0 ref | 充足 |
| §4.10 Release/deploy/secret は人間ゲート | 本リポジトリの deploy 機構は自動実行経路を持たない（別監査 task-3） | 充足 |
| §5.8 Auto-Merge 登録 | 22 件中 `autoMergeRequest` が非 null は **1 件のみ（#172）**。残り 21 件は登録なしで merge | **解釈注意**（下記 5.3） |
| §6 ruleset `central-auto-merge` が active | ruleset id `20882817` `central-auto-merge` enforcement=`active`、必須=`Secrets scan (gitleaks)` / `linux-validate` | 充足 |
| §6 Repository settings | `allow_auto_merge=true`, `delete_branch_on_merge=true`, `allow_squash_merge=true`（merge commit / rebase は false） | 充足 |

測定コマンド（読み取りのみ）:

```
gh pr view <n> --json statusCheckRollup,autoMergeRequest,mergedAt   # n=171..192
gh pr list --state merged --limit 40 --json number,mergedBy,mergeCommit
gh api repos/Kensan196948G/Claude-StartUpTools-New-Linux/rulesets
gh api repos/Kensan196948G/Claude-StartUpTools-New-Linux --jq '{allow_auto_merge,delete_branch_on_merge,...}'
```

実測値: 対象 22 件（#171〜#192）、mergedAt は 2026-11-23T01:01:59Z〜2026-11-23T03:29:40Z、mergedBy は 22/22 が `Kensan196948G`（人間アカウント）。

### 5.2 v3 で「新たに」失格になる項目

**ない。** v3 の追加は §10（対象外リポジトリの緩和）と §3 の注意書きのみで、本リポジトリの義務を増やさない。§1・§2・§4〜§9 は本文一致（§2 の表）。

### 5.3 解釈上の注意（v2 から存在する論点・v3 で未解消）

- §5 は「GitHub Controller が以下を順に実行する」という**主体別の責務**として書かれている。§5.8 の auto-merge 登録は Controller 経由の merge を想定した手順であり、人間が Required Checks PASS 後に手動 squash する行為を禁止する条文は v3 に存在しない（§4.6 / §4.8 の条件を満たせば足りる）。
- ただし「全 merge は Controller の auto-merge 経由でなければならない」と読む解釈も成立し得る。その場合 21/22 が非適合となるが、これは **v2 時点から同じ**であり、v3 の差分に起因しない。運用を厳密に揃えるなら、Controller 経由へ寄せるか、§5.8 を「Controller を用いる場合の手順」と明記するかのいずれかを人間が選ぶ必要がある（本タスクでは変更しない）。

---

## 6. 参照 3 パスの問題と、v3 追随時に必要な修正

### 6.1 実測: 参照先は本リポジトリに存在せず、中央に存在する

| 参照（本リポジトリ v2 の行） | 本リポジトリ | 中央（`/home/kensan/Projects/Deep-Seek-Harness-Project/`） |
|---|---|---|
| ヘッダ L3: `docs/architecture/全リポジトリAutoMerge統一方針.md` | **無し** | 有り |
| §6 L97: `bin/policy-pr.sh` | **無し** | 有り |
| §7 L131: `bin/github-controller.sh` | **無し** | 有り |

コマンド: `for p in bin/policy-pr.sh bin/github-controller.sh docs/architecture/全リポジトリAutoMerge統一方針.md; do [ -e "$p" ] && echo EXISTS || echo MISSING; done`

### 6.2 v3 はこの参照を直していない

- 差分は 3 箇所のみ（§1）。参照 3 件の記述は v3 でも v2 と**同一**（中央 §6 L99 / §7 L133 / ヘッダ L3）。
- したがって **v3 に追随しても、配布先で参照が解決しない問題はそのまま残る**。
- 参考: v3 自身は §10 で他リポジトリの実装を `Construction-World-Model-Platform/01_construction-world-model-management` の `decisions/…` と、**リポジトリ名で修飾して**参照している。中央が cross-repo 参照に使っている流儀はこちら。

### 6.3 修正案（v3 追随時に併せて行う。ポリシー本文の変更ではなく参照表記の修正）

| 案 | 書き方の例 | 長所 | 短所 |
|---|---|---|---|
| R1（推奨） | 「中央リポジトリ `DeepSeek-Harness-StartUpTools` の `bin/policy-pr.sh`」 | 配布先でも意味が通る。パス追加不要 | 中央リポジトリ名の変更に追随が必要 |
| R2 | 絶対パス `/home/kensan/Projects/Deep-Seek-Harness-Project/bin/policy-pr.sh` | 一意 | マシン依存。配布先で壊れる |
| R3 | 実体を vendor（本リポジトリにコピー） | 参照が解決する | 二重管理・ドリフト。§8 の「中央が正本」と矛盾 |
| R4 | 「本コピーには含まれない（中央を参照）」と注記 + リンクのみ | 誤解が最少 | 実行手順としては弱い |

併せて推奨: **ヘッダに「本コピーの版 / 正本 / 同期元」を 1 行追加**する。例:

```
本コピー: v3（2026-10-05）/ 正本: DeepSeek-Harness-StartUpTools（中央）の GITHUB_POLICY.md
```

これがあると、今回のような「ローカルは v2、中央は v3」の stale mirror を機械的に検出できる（`AGENTS.md:30` は既に中央を正本と明記しているが、コピー側に版の記載がない）。

---

## 7. 統一の選択肢（3 案）

### 案 A: 本リポジトリを v3 へ追随

- **内容**: 中央 v3 をローカル `GITHUB_POLICY.md` に反映（+ ヘッダに版/正本を明記、参照 3 件を R1 で修正）。
- **影響**: 本リポジトリの運用義務は変わらない（§2 の表）。§10 は対象外。ドリフトの解消により、仕様書の「コピーは同一内容」という記述が**再び真になる**。
- **リスク**: 低。差分は加算のみ（削除はヘッダ 1 行の置換）。§10 を読んだ人が「自リポジトリも除外できる」と誤読する余地は §3 の注意書きで塞がれている。
- **作業**: (1) v3 コピー (2) 参照 3 件の修正 (3) ヘッダ追記 (4) 仕様書 `GitHub開発運用仕様.md:4` の記述確認 (5) PR（人間レビュー）。
- **人間ゲート**: 不要（コピーの更新のみ）。ただし §8 に照らし、ポリシー本文の**変更**ではないことを PR 本文に明記する。

### 案 B: 中央で v3 を v2 相当へ戻す

- **内容**: 中央 `GITHUB_POLICY.md` から §10 と §3 の注意書き・ヘッダ追記を削除。
- **影響**: `mirai-construction-dx/Mirai-Platform-Infra` の適用除外が消え、§5.8（auto-merge 登録）と §6（`Allow auto-merge`: ON）が同リポジトリにも適用される。
- **リスク**: **高**。人間が 2026-10-05 に Y 承認した例外（§10 承認根拠）を巻き戻す。同リポジトリは `scripts/mergegate.py` を持ち（ローカル実測）、bot approve + 人間 Y の方式へ移行中と見られる。ここで auto-merge を復活させると、移行途中の統制と衝突し得る。
  - 未確認: §10 の施行条件（`Allow auto-merge`: OFF、`Allow GitHub Actions to create and approve pull requests`: ON）は**充足していない**可能性が高い（`gh api` 実測で `allow_auto_merge: true`）。またローカル clone には `decisions/ADR-0011-…` と `.github/workflows/merge-gate.yml` が見当たらない（clone が古い可能性あり）。
- **作業**: 中央の変更 + 再承認（§8）+ 全配布先への再配布。本リポジトリ側の作業は無し。
- **人間ゲート**: 必須（§8「本ポリシー自体の変更」）。

### 案 C: 版ごとに配布対象を分ける（v2/v3 併存を正式化）

- **内容**: 「v3 は §10 対象リポジトリのみ、それ以外は v2」という配布方針を明文化し、配布台帳（repo → 版 → 理由）を持つ。
- **影響**: 中央は v3 のまま。本リポジトリは v2 を維持。ただし「v3 = v2 + リポジトリ限定例外」という関係を台帳に明記しないと、v3 を「追加義務のある新版」と誤解する。
- **リスク**: 中。版の二重管理により、次に §1〜§9 が改訂されたとき v2 側が取り残される。また「どの版が適用されるか」を repo ごとに人が確認する運用コストが常設化する。
- **作業**: 配布台帳の新設（正本の置き場・更新手順・ドリフト検査）、本リポジトリの版の明示、CI か定期チェックでの版一致検査。
- **人間ゲート**: 必須（配布方針の決定。ポリシー本体は変えないが §2 適用範囲の運用に関わる）。

### 比較表

| 観点 | A: v3 追随 | B: 中央を v2 相当へ | C: 版を分ける |
|---|---|---|---|
| 本リポジトリの義務の変化 | なし | なし（中央変更のみ） | なし（v2 維持） |
| ドリフト解消 | ○（コピーが v3 に一致） | ○（中央が v2 に戻る） | △（併存を正式化するが解消はしない） |
| 他リポジトリへの影響 | なし | **大**（例外の巻き戻し） | 中（台帳の整備が必要） |
| 必要な人間承認 | コピー更新のみ | §8 の再承認 | 配布方針の決定 |
| 主なリスク | 低（参照 3 件を直さないと誤解は残る） | 高（移行中の統制と衝突） | 中（版の取り残し・確認コスト） |

### 推奨（決定は人間）

**案 A**（+ §6.3 の R1 とヘッダの版/正本明記）。理由:

1. v3 は本リポジトリの義務を増やさない（§2 の節単位一致で確認）。
2. §10 は明示的に対象外（「のみ。他リポジトリへ拡大しない」）。
3. 案 B は承認済みの他リポジトリ例外を巻き戻すため、本件の目的（本リポジトリの統一）に対して過剰。
4. 案 C は「併存の正式化」であり、v3 が v2 の上位互換である以上、分ける積極理由が弱い（§1〜§9 の改訂が今後分岐するなら再検討）。

---

## 8. 案 A を採る場合の作業手順（人間ゲート付き）

1. 中央 v3（`10552B` / 195 行）をローカル `GITHUB_POLICY.md` へ反映する。**内容は一字も変えない**（参照 3 件の修正は別コミットに分ける）。
2. ヘッダに「本コピー: v3（2026-10-05）/ 正本: 中央」を追記する（§6.3）。
3. 参照 3 件を R1 形式へ修正する（§6.3 の表）。あわせて `docs/architecture/GitHub開発運用仕様.md:4` の「コピーは同一内容」を、版を明記する記述へ更新するか確認する（同ファイルは本タスクの write scope 外のため、**別タスクで扱う**）。
4. PR 本文に「ポリシー本文の変更ではなく、中央正本のコピー更新である」こと、差分が §1 の 3 箇所のみであることを記載する。
5. レビューと merge は人間（本ポリシー §8 に照らし、ポリシー変更と誤認されないよう明記する）。

**やらないこと**: 中央リポジトリへの書き込み、ruleset の変更、`GITHUB_POLICY.md` の内容改変（本タスクは分析のみ）。

---

## 9. 未確認・推測

| # | 項目 | 状態 |
|---|---|---|
| U1 | 中央リポジトリの git 履歴（中央 v2 の byte 同一性） | **未確認**（中央への git 操作は禁止）。代替根拠として、他の v2 配布 2 本と md5 一致を確認 |
| U2 | §10 対象リポジトリの施行条件の充足 | **未確認**。`gh api` 実測で `allow_auto_merge: true`（§10 は OFF 前提）。ローカル clone に `decisions/ADR-0011-…` と `.github/workflows/merge-gate.yml` は見当たらず、`scripts/mergegate.py` のみ存在。clone が古い可能性あり |
| U3 | 配布台帳の正本（どの repo にどの版を配るか） | **未確認**。task-21 背景の「v1×3 / v2×5 / v3×1」は再測定していない |
| U4 | 5407B の変種 6 本の位置づけ | **未確認**（ヘッダは v1・9 節・auto-merge 記述あり＝移行期の版と推測） |
| U5 | PR #171〜#192 の merge 操作が `--auto` 経由か手動か | API 上 `autoMergeRequest` 非 null は 1/22 のみ。残りは**手動と推測**（一次記録は未確認） |
| U6 | `e2e-console` 等が Required Checks に含まれない理由 | 未確認（ruleset の必須は 2 件のみ。意図は不明） |

---

## 10. 付録: 再現コマンド

### 10.1 差分

```bash
diff -u /home/kensan/Projects/Claude-StartUpTools-New-Linux/GITHUB_POLICY.md \
        /home/kensan/Projects/Deep-Seek-Harness-Project/GITHUB_POLICY.md
```

期待: 3 hunk（ヘッダ / §3 / §10）、+46 行 / -1 行。

### 10.2 節単位の一致判定

```bash
for f in A B; do
  grep -n '^## ' "$f" | cut -d: -f1   # 節の開始行
done
# 各節の本文を sed -n 'start+1,end p' で切り出し md5sum を比較
```

実測（本文 md5）:

| 節 | v2 | v3 | 一致 |
|---|---|---|---|
| §1 | `8db01759…` | `8db01759…` | ○ |
| §2 | `d02963a5…` | `d02963a5…` | ○ |
| §3 | `f2a29760…` | `06b7c964…` | ×（追加 2 行） |
| §4 | `6e0656dd…` | `6e0656dd…` | ○ |
| §5 | `1fe437ba…` | `1fe437ba…` | ○ |
| §6 | `f59ab454…` | `f59ab454…` | ○ |
| §7 | `f4a941e3…` | `f4a941e3…` | ○ |
| §8 | `f0304fdb…` | `f0304fdb…` | ○ |
| §9 | `fddb272b…` | `d3a15c23…` | ×（境界の末尾空行のみ。本文は一致） |

### 10.3 参照 3 パスの存在確認

```bash
for p in bin/policy-pr.sh bin/github-controller.sh docs/architecture/全リポジトリAutoMerge統一方針.md; do
  [ -e "/home/kensan/Projects/Claude-StartUpTools-New-Linux/$p" ] && echo "LOCAL $p" || echo "LOCAL MISSING $p"
  [ -e "/home/kensan/Projects/Deep-Seek-Harness-Project/$p" ] && echo "CENTRAL $p" || echo "CENTRAL MISSING $p"
done
```

### 10.4 運用実績（読み取りのみ）

```bash
gh pr list --state merged --limit 40 --json number,mergedBy,mergeCommit,headRefName
gh pr view <n> --json statusCheckRollup,autoMergeRequest,mergedAt   # n=171..192
gh api repos/Kensan196948G/Claude-StartUpTools-New-Linux/rulesets
gh api repos/Kensan196948G/Claude-StartUpTools-New-Linux --jq '{allow_auto_merge,delete_branch_on_merge}'
```
