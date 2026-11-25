# 影響分析とロールバック: エージェントの指示書を R0 から R2 へ（PR #237、R4）

状態: 2026-11-25。PR #237 の R4 要件（変更影響分析・ロールバック手順）を満たすための文書。`/ship 237` の指摘（7 件）を反映済み（§4）。

## 1. 変更内容

### 1.1 リスク分類の規則（`config/ship-policy.json`）

`risk.rules` の R3 と R1 の間に R2 の規則を 1 つ追加する。規則は先頭から評価されるため、R0（`**/*.md`）・R1 より先に当たる。
glob は大文字小文字を区別する（`scripts/ship/lib/risk.js`）ため、表記揺れは列挙する。スラッシュを含まないパターンは任意の階層にも当たる。

| 種類 | パターン |
| --- | --- |
| ファイル名（任意の階層） | `CLAUDE.md`・`Claude.md`・`claude.md`、`CLAUDE.local.md`（同 3 表記）、`AGENTS.md`・`Agents.md`・`agents.md`、`AGENTS.override.md`、`GEMINI.md`（同 3 表記）、`.cursorrules` |
| パス | `**/SKILL.md`、`**/skill.md`、`**/copilot-instructions.md`、`**/*.instructions.md` |
| 設定ディレクトリ（入れ子を含む） | `.claude/**`・`**/.claude/**`、`.codex/**`・`**/.codex/**`、`.agents/**`・`**/.agents/**`、`.cursor/**`・`**/.cursor/**` |
| 配布テンプレート | `Claude/**`、`Codex/**` |

### 1.2 変更ファイルの取得（`scripts/ship/lib/github.js` の `changedFiles`）

`gh pr view --json files`（新しいパスだけを返す）から、REST の `pulls/{n}/files` に変更した。

- **リネーム・コピーは変更前のパス（`previous_filename`）も返す。** 指示書（R2）を `docs/`（R0）へリネームしても、旧パスが分類されて R2 以上になる
- ページを結合し、PR の `changed_files` と件数が合わなければ `FILES_INCOMPLETE` で失敗する（GitHub の上限 3000 件を超える場合など）。gate は失敗時に R4 として扱う（既存の安全側の挙動）
- 引数（リポジトリ名・PR 番号）を検証する

## 2. 影響分析

### 2.1 分類の変化（追跡ファイル全件、2026-11-25 実測）

| | R0 | R1 | R2 | R3 | R4 |
| --- | --- | --- | --- | --- | --- |
| 変更前（main） | 662 | 117 | 284 | 16 | 73 |
| 変更後 | 88 | 115 | 860 | 16 | 73 |

- R0→R2: 574 件（エージェントの指示書。`.claude/rules/*.md`、`Claude/CLAUDE.md`、`scripts/templates/AGENTS.md` など）
- R1→R2: 2 件（`.claude/claudeos/tests/lib/utils.test.js`、`Claude/templates/claudeos/tests/lib/utils.test.js`。エージェントの環境に配布されるテスト。R2 の規則が R1 より先に評価されるため）
- R3・R4 は変化なし。上位規則（`.claude/settings.json`=R4、`**/hooks/**`=R4 など）は先に評価されるため優先されたまま
- R0 に残るのは `docs/**`・`reports/**`、ルートの `README.md`・`CHANGELOG.md`・`TASKS.md`・`ONBOARDING.md`・`LICENSE`、`.github/ISSUE_TEMPLATE/*`・`PULL_REQUEST_TEMPLATE.md`、`config/README.md`・`formal/README.md`

### 2.2 運用への影響

| 対象 | 影響 |
| --- | --- |
| 指示書を変える PR | R0 から R2 になり、**Ship レビュー（`/ship` と署名）が設定上の必須になり、ロールバック手順の文書（`--rollback-doc`）も新たに必要になる**。なお現行コードでは R0 でも Ship 署名が無いと gate は CONDITIONAL で承認できないため、Ship 署名は実質的に今も必要 |
| 通常の文書だけの PR | 変化なし（R0 のまま） |
| リネームを含む PR | 旧パスも分類されるため、リスクが上がることがある（安全側） |
| 後続 PR #238（R0・R1 の human-diff） | この変更が前提。指示書を含む PR では human-diff が使えなくなる（意図どおり） |
| マージ判定・承認・ruleset | 変化なし |
| gate の判定ロジック | 変化なし（入力のファイル一覧に旧パスが加わるだけ） |
| GitHub API の呼び出し | gate・classify ごとに REST 2 回（ファイル一覧のページ数 + PR 本体）。従来は GraphQL 1 回 |

### 2.3 効く時期

gate は main 上のポリシー（`loadTrustedPolicy`）を使うため、新しい分類はこの PR のマージ後に作られる gate から使われる。
`changedFiles` の変更は実行するコードの変更なので、マージ後に main を取り込んだ clone から効く。マージ前に作られた gate の記録は変わらない。

### 2.4 リスクと既知の限界

- **広く当たる（安全側）**: `Claude/**` は配布テンプレート全体（指示書以外も含む）を R2 にする。`.claude/claudeos/data/*.json`（学習データ）は以前から既定値 R2 で、この PR による変化ではない
- **当たり漏れ（既知）**:
  - `docs/architecture/**`・`docs/claude/**` にもエージェントが読むポリシー文書があるが、R0 のまま。人向けの設計文書と区別できないため、今回は対象外とする。エージェントが自動で読み込む場所（`CLAUDE.md` からの参照など）に移す場合はパターンを追加する
  - 上の表に無い独自名の指示書。見つけ次第パターンを追加する
  - `CLAUDE-back.md`・`docs/MY_AGENTS.md` のような名前は意図的に対象外（テストで R0 を確認）
- **取得の失敗**: 変更ファイルが取れない・取り切れない場合は R4（既存の挙動）。3000 件を超える PR は常に R4 になる

## 3. ロールバック手順

1. この PR を `git revert` する PR を作る（変更は `config/ship-policy.json` の 1 ブロック、`scripts/ship/lib/github.js` の `changedFiles`、テスト、この文書）
2. revert PR も R4 なので、いつもどおり品質検証 → `/ship` → 署名 → 品質判定 → 承認 → マージ
3. マージ後、`node -e 'console.log(require("./scripts/ship/lib/risk").classifyFile("CLAUDE.md", require("./config/ship-policy.json").risk).level)'` で `R0` に戻ることを確認する
4. 後続の PR #238 がマージ済みの場合は、先に #238 を戻す（#238 を残したまま戻すと、指示書が human-diff の対象になる）

データの移行・削除は無い。設定値とコードを戻すだけで元の挙動に戻る。

## 4. `/ship 237` の指摘への対応（2026-11-25）

| # | 指摘 | 対応 |
| --- | --- | --- |
| 1 | リネームで R2 を回避できる（`changedFiles` が新パスのみ）【important】 | §1.2。REST で旧パスも分類。テスト追加（外すと失敗することを確認） |
| 2 | `Codex/templates/**` に一致する実ディレクトリが無く、実在する `.codex/` が漏れている | `.codex/**`・`**/.codex/**` を追加、`Codex/**` は将来用に残す |
| 3 | `CLAUDE.local.md`・入れ子の `.claude/`・大文字小文字違いが R0 のまま【important】 | §1.1。表記揺れと入れ子を列挙。テスト追加 |
| 4 | 「R0 でも今から Ship レビュー必須」の記述が誤り | §2.2 を訂正（設定上は R2 で新たに必須。現行コードでは実質必須） |
| 5 | `.claude/claudeos/data/*.json` は元から既定値 R2 | §2.4 を訂正 |
| 6 | `docs/architecture/**` などのポリシー文書が R0 のまま | §2.4 に既知の限界として明記（今回は対象外） |
| 7 | R1→R2 の順序依存・紛らわしい名前・リネーム・入れ子が未テスト | テスト追加（`core.test.js`・`github.test.js`） |
