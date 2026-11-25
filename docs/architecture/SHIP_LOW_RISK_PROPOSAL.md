# R0・R1 の運用を軽くする変更案（提案・未適用）

状態: 2026-11-25 **案 A を採用し実装（未マージ）**。前提の修正（§5）は別 PR、案 A の実装は §7。マージには R4 の手順（`/ship` → 署名 → 承認）が必要。

## 1. 問題

ruleset 第 1 段階（2026-11-24 20:30 適用）以降、すべての PR は次の手順を通らないとマージできない。

1. ローカル品質の検証（AI、実測で約 12 分）
2. `/ship` によるレビュー（人。対話セッションで入力が必要）
3. `ship-attest` で結果に署名（人）
4. 品質判定 PASS（AI）
5. `approve` で承認（人）

R0（文書のみ）の PR でも 2・3 が省けない。現行コードの動き（`scripts/ship/lib/quality-gate.js`）:

| リスク | Ship 署名なし | 承認できるか |
| --- | --- | --- |
| R0・R1 | `ship.reviewed = CONDITIONAL`（「必須ではないが人が確認する」） | **できない**（`issueApproval` は PASS 以外を拒否） |
| R2〜R4 | `ship.reviewed = UNKNOWN`（「Ship 必須」） | できない |

つまり `ship.requiredForRisk = ["R2","R3","R4"]` という設定は、実際には R0・R1 にも Ship 署名を求めている。設定の意図と挙動が一致していない。

### 実測（PR #235、R0・文書 5 ファイル）

- 人の手順: `/ship` の起動と待ち（約 15 分。指摘 7 件の確認を含む）、署名、承認
- `/ship` の指摘 7 件はすべて文書の古い記述で、内容としては有用だった

### 頻度（直近 60 件のマージ済み PR、2026-11-23〜24、現行の規則で分類）

| R0 | R1 | R2 | R3 | R4 |
| --- | --- | --- | --- | --- |
| 12 | 1 | 24 | 11 | 12 |

R0・R1 は 13 件（約 22%）。**案の効果はこの範囲に限られる。** R2 以上（約 78%）は今と変わらない。

## 2. 案

### 案 A（推奨）: R0・R1 に限り「人の差分確認」の署名を Ship レビューの代わりに認める

`ship-attest` に新しい種類 `review_kind: "human-diff"` を加える。人が `gh pr diff` で差分を読み、問題が無いことを署名する。

| 項目 | 内容 |
| --- | --- |
| 対象 | **R0・R1 のみ**。gate が分類したリスクで判定し、R2 以上では `human-diff` 署名を無視する（Ship 署名が必要なまま） |
| 署名の中身 | head SHA 固定、`reviewed=true`、`important_open=0`、`review_kind="human-diff"`、確認した変更ファイル数 |
| 判定 | R0・R1 で有効な `human-diff` 署名があれば `ship.reviewed = PASS`（`source=human-diff-attestation:…`） |
| 承認 | 今と同じ。PASS の gate にだけ、人が `approve` する |
| 変わらないもの | ローカル品質（12 分）、承認、ruleset、SHA 固定、承認後の push で無効化 |

人の手間: `/ship` の起動・待ち（約 15 分）→ 差分を読んで署名（文書 PR なら数分）。**承認は残る。**

### 案 B: R0・R1 は Ship 署名を不要にし、承認だけにする

`ship.reviewed` を R0・R1 では評価しない（PASS 扱い）。

- 手順は最も短い（品質検証 → 承認）
- ただし「人が中身を見た」ことの記録が承認だけになる。承認は「判定結果を見て OK を出す」もので、差分を読んだことの証明ではない

### 案 C: 現状維持

R0・R1 でも `/ship` と署名を続ける。安全性は最も高いが、手間は今のまま。

## 3. 比較

| | 案 A | 案 B | 案 C |
| --- | --- | --- | --- |
| R0・R1 の人の手間 | 中（差分確認 + 署名 + 承認） | 小（承認のみ） | 大（`/ship` + 署名 + 承認） |
| 「人が中身を見た」証跡 | あり（署名） | 弱い（承認のみ） | あり（`/ship` + 署名） |
| AI 自身の判断で通る経路 | 増えない | 増えない | 増えない |
| R2 以上への影響 | なし | なし | なし |
| 変更範囲（R4） | `quality-gate.js`・`human-gate.js`・`approve.js`・`ship-policy.json`・テスト | `quality-gate.js`・`ship-policy.json`・テスト | なし |

どの案でも **AI だけで PR が通ることは無い**（承認には人のパスフレーズが必要なまま）。

## 4. リスクと対策（案 A）

| リスク | 対策 |
| --- | --- |
| R0 に見えて実は危ないファイルが混ざる | 判定は**変更ファイル全体の最大値**（現行どおり）。1 ファイルでも R2 以上なら案 A は効かない。R0 のパターンは `docs/**`・`**/*.md`・`LICENSE`・`reports/**` だけ |
| `**/*.md` に手順書（実行される内容を含む文書）が入る | `.claude/**/*.md`・`Claude/templates/**/*.md`（エージェントへの指示になる文書）を R0 から外し、R2 以上にする。**案 A の前提として同時に行う** |
| 分類の取り違え（R0 と判定されるべきでないものが R0） | `risk.classified` の詳細（ファイル別の判定）を承認の確認画面に表示する（現行で表示済み） |
| 差分を読まずに署名する | 技術的には防げない（`/ship` 署名と同じ限界）。署名は人の宣言として残り、監査ログに記録される |
| ポリシーを AI が書き換えて R0 を広げる | `ship-policy.json` は R4。変更には Ship 署名と承認が必要（今と同じ） |

## 5. 前提の修正（案 A・案 B 共通で推奨）

現行の R0 パターン `**/*.md` は、エージェントの指示書（`.claude/**`、`Claude/templates/**`、`AGENTS.md`、`CLAUDE.md`）にも当たる。
これらは**プロンプト注入の経路**になり得るため、R0 として軽く扱うべきではない。案の適用前に、少なくとも次を R2 以上にする:

- `.claude/**`、`Claude/templates/**`、`AGENTS.md`、`CLAUDE.md`、`**/SKILL.md`

この修正は単独でも価値がある（今は R0 の判定でも Ship 署名が実質必須のため問題が表に出ていないだけ）。

実測（2026-11-25、`scripts/ship/lib/risk.js` の `classifyFile` を現行の `config/ship-policy.json` で実行）:

| ファイル | 判定 | 当たったパターン |
| --- | --- | --- |
| `CLAUDE.md`・`AGENTS.md`・`.claude/CLAUDE.md` | R0 | `**/*.md` |
| `.claude/rules/hooks.md` | R0 | `**/*.md` |
| `Claude/templates/claude/CLAUDE.md` | R0 | `**/*.md` |
| `.claude/skills/verify-startuptools/SKILL.md` | R0 | `**/*.md` |
| （比較）`.claude/settings.json` | R4 | `.claude/settings.json` |

該当する追跡ファイル（`.claude/*.md`・`Claude/templates/*.md`・`AGENTS.md`・`CLAUDE.md`・`**/SKILL.md`）は **582 件**。
設定ファイルは R4 なのに、同じくエージェントの動作を決める指示書は R0 になっている。

## 6. 実装する場合の作業（参考・未着手）

1. `ship-policy.json`: R0 から指示書系を除外する規則を R2 として先に追加。`humanGate.lowRiskReviewKinds = { "R0": ["ship","human-diff"], "R1": ["ship","human-diff"] }` を追加
2. `human-gate.js`: `issueShipAttestation` に `reviewKind`（`ship` 既定 / `human-diff`）を追加し、署名対象に含める
3. `quality-gate.js`: リスクと `review_kind` の組み合わせで `ship.reviewed` を判定。許可されない組み合わせは無視
4. `approve.js`: `ship-attest --kind human-diff` と、確認画面での差分ファイル一覧の表示
5. テスト: R0 で PASS、R2 で無視、署名の改ざん、head 変更で無効、指示書系が R2 になること
6. TLA+ モデル（`formal/specs/ship_gate.tla`）: 承認なしでマージできない性質が変わらないことを再検証

これらはすべて R4 の変更で、**Ship 署名と承認の手順を通して入れる**。

## 7. 実装（2026-11-25、案 A・未マージ）

### 変更点

| ファイル | 内容 |
| --- | --- |
| `config/ship-policy.json` | 指示書を R2 にする規則（別 PR）と、`humanGate.reviewKindsByRisk`（R0・R1 は `ship` と `human-diff`、R2〜R4 は `ship` のみ） |
| `scripts/ship/lib/human-gate.js` | 署名の新形式 `claudeos.ship-attestation/v2`（`review_kind`・`files_reviewed` を署名対象に含める）。v1（従来の `/ship` 署名）はそのまま有効。`shipEvidenceFor` は gate が計算したリスクで種類を選別 |
| `scripts/ship/lib/quality-gate.js` | 二重の防御: 証跡の種類がそのリスクで認められなければ `ship.review_kind=UNKNOWN` とし、証跡なしとして扱う |
| `scripts/ship/ship.js` | `gate` が変更ファイルから計算したリスクを証跡の選別に渡す（取得できなければ R4 = `ship` のみ） |
| `scripts/ship/approve.js` | `ship-attest --kind human-diff`: 変更ファイルとリスクを表示し、R2 以上なら拒否、確認の `yes` とパスフレーズで署名 |

### 使い方（R0・R1 の PR）

```bash
gh pr diff <番号>                       # 差分を読む
bash bin/ship-approve.sh ship-attest --kind human-diff \
  --repo Kensan196948G/Claude-StartUpTools-New-Linux --pr <番号> --head <SHA> --important-open 0
```

### 守り（テストで確認）

| 性質 | 確認方法 |
| --- | --- |
| R0・R1 では human-diff 署名で gate PASS | 単体・CLI 通しテスト |
| R2 以上では human-diff 署名を無視（証跡の選別と gate の両方で） | 単体テスト。**それぞれの防御を外すとテストが失敗する**ことを確認 |
| 同じ署名が残っていても、PR が R2 以上の変更を含むようになれば認めない | CLI 通しテスト |
| R2 以上の PR では署名そのものを拒否 | CLI 通しテスト（`HUMAN_DIFF_NOT_ALLOWED_FOR_R2`） |
| `review_kind`・`files_reviewed`・head の改ざん、v2→v1 の偽装は検証で弾く | 単体テスト。**署名対象から外すとテストが失敗する**ことを確認 |
| 従来の `/ship` 署名（v1）は全リスクで有効 | 単体テスト |
| `reviewKindsByRisk` が無い旧ポリシーでは `ship` のみ | 単体テスト |
| 承認なしでマージできない（TLA+） | `ship_gate.tla` を再検証（verified、25,352 状態）。今回の変更はレビュー証跡の種類だけで、承認・マージの規則は変えていないためモデルの変更は不要 |

### 効く時期

gate・承認は **main 上のポリシー**（`loadTrustedPolicy`）を使う。この PR と前提の PR がマージされるまでは、R0・R1 でも従来どおり `/ship` 署名が必要。
