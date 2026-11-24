# /ship の実機確認手順（人が行う）

目的: 対話型 Claude Code セッションで `/ship` が使えることを、**何も変更せずに**確かめる。
`/ship` は公式仕様で「人が入力した行」からしか起動しないため、AI は代行できない（`claude -p` では `Nothing started`）。

## 1. 安全な確認（何も変更しない）— まずこれだけ

`/ship terms` は「watch 中に Claude がしてよいこと・制限」を表示するだけで、コミット・push・PR 作成をしない。

```bash
cd ~/Projects/Claude-StartUpTools-New-Linux
claude
```

起動したプロンプトで、次の順に入力する（毎回 Enter）:

| # | 入力 | 確認すること |
| --- | --- | --- |
| 1 | `/` | 候補一覧に `/ship-local`（`/ship` の実体のスキル名）と `/steward` が出る。2026-11-24 の実機では `/ship` という名前では表示されなかった（§5） |
| 2 | `/ship terms` | watch の制限（merge / approve / auto-merge 有効化 / force-push を止める等）の説明が表示される |
| 3 | `/tasks` | watch は動いていない（一覧に `/steward --tend` が無い） |
| 4 | `/exit` | 終了 |

結果の見方:

| 表示 | 意味 |
| --- | --- |
| 制限の説明が出る | **成功**。`/ship` はこの環境で使える |
| `Unknown command: /ship`、または `/code-review` が始まる | 未配信。`claude update` 後に 2 回起動し直す（公式の手順） |
| `Skill "ship-local" is disabled via skillOverrides` | 設定で無効化されている |
| `/ship is turned off right now` | `/login` をやり直す |

## 2. やってはいけないこと（この確認の範囲外）

- **引数なしの `/ship` を main で実行しない。** `/ship` は確認なしで、未コミットの変更をコミットし、新しいブランチを push し、PR を開く。
  このフォルダには ClaudeOS の学習データ（`.claude/claudeos/data/*.json`）の未コミット変更が常にあり、それが PR に含まれてしまう。
- 本リポジトリは **auto-merge が有効**で、ruleset は人間承認をまだ要求していない（承認事項 #3 が未）。
  公式 docs の警告どおり、auto-merge が登録された PR では watch の push がそのままマージに至り得る。

## 3. 実際に /ship を使うとき（次の段階）

本当の PR で試すときは、次を満たしてから行う:

1. 専用の作業ブランチと、**別の clone**（未コミットの学習データが無いところ）で行う
2. 先にドラフト PR を自分で作る（`/ship` は既存 PR があればそれを使い、未コミットの変更はコミットしない）
3. その PR に auto-merge を登録しない
4. 終わったら `/ship stop` で watch を止め、結果を署名で残す（`bin/ship-approve.sh ship-attest`）

## 4. 結果の記録

確認できたら、結果（成功 / 表示されたメッセージ）を伝えてもらえれば、AI が `docs/architecture/SHIP_DEVELOPMENT_STATUS.md`
と `config/claude-code-compat.json` の該当項目（`ship-command` / `steward-command`）を「実機確認済み」に更新する PR を作る。

## 5. 実機確認の結果（2026-11-24 17:42、人が実施）

| 項目 | 結果 |
| --- | --- |
| `/` の候補 | `/ship-local`（`/ship` の実体のスキル名）と `/steward` が表示された |
| 1 回目の `/ship terms` | `Nothing started. /ship starts only from a line that you type, not from claude -p or a program.`（起動直後の非同期 SessionStart フックと重なった入力が「人の入力」と判定されなかったとみられる。**推測**） |
| 2 回目の `/ship terms` | **watch の条件と制限の全文が表示された（成功）**。コミット・push・PR 作成は行われていない |
| `/tasks` | `No tasks currently running`（watch は動いていない） |

**結論: 本環境（Claude Code 2.1.330 / Max）で `/ship` と `/steward` は利用できる。**
1 回目が起動しなかったときは、起動直後のフックが終わってから（プロンプトが落ち着いてから）もう一度入力する。

### `/ship terms` が示した注意点（本環境固有）と ClaudeOS の評価

| `/ship terms` の表示 | 原因（読み取りで確認） | 評価・対応 |
| --- | --- | --- |
| `Deny rule Write(.claude/settings.json) never matches · use Edit(.claude/settings.json)` | 本リポジトリとテンプレートの `permissions.deny` に `Write(.claude/settings.json)` がある | 同じ deny に `Edit(.claude/settings.json)` も既にあるため保護は効いている。`Write(...)` の行は効果の無い記述。整理する場合は R4（権限設定）として別 PR |
| 「permission rules here let a shell, an interpreter, a task or test runner ... run unasked」 | `.claude/settings.json` の allow に `npm run *`・`node scripts/*`・`bats *`・`bash scripts/*`・`bash tests/*`・`make *` など | **watch の制限を迂回できる経路**。テストやスクリプトは gh/git をあなたの資格情報で実行できる。ClaudeOS の自律開発には必要な許可なので削除は推奨しない。対策は ruleset による人間承認の必須化（承認事項 #3） |
| 「a PreToolUse or PermissionRequest hook runs on shell commands ... where it answers "allow"」 | ユーザー設定 `~/.claude/settings.json` の PreToolUse（`kensan-auto-merge-guard.py`、matcher `Bash|mcp__github__merge_pull_request`） | このフックは **deny しか返さない**（allow を返すコードが無いことを確認）。Claude Code は「allow を返し得る」ことを一般的に警告している。実害は無いが、表示は消えない |
| 「If auto-merge is on for this pull request, GitHub merges it ...」 | 本リポジトリは `allow_auto_merge=true` | `/ship` で試す PR に auto-merge を登録しない（手順 §3） |
| 「For a public repository, commit your work yourself first」 | 本リポジトリは PUBLIC | 手順 §3 のとおり、先に自分でコミットしドラフト PR を作ってから `/ship` |

## 6. 実 PR での練習の結果（2026-11-24 18:30〜19:48、PR #230）

PR #230（文書のみ・R2）を使い、Ship Native の全工程を人とAIで分担して通した。

| 工程 | 担当 | 結果 |
| --- | --- | --- |
| ローカル品質（隔離実行・8 チェック） | AI | PASS（npm-test 2,095 pass / 0 fail / 3 skip）。`claudeos/local-quality=success` |
| `/ship 230`（レビュー） | 人 | 指摘 8 件。すべて文書の古い記述・曖昧さで、コードの不具合の指摘は無し |
| 指摘の反映 | AI | `/ship` が作業ツリーで直した 4 件を確認して取り込み、残り 4 件を Lead が反映（`1d87dab`） |
| ローカル品質（新しい head で再実行） | AI | PASS |
| `ship-attest`（結果への署名） | 人 | `sa_mwukbrfc_405adedd7cec`（important_open=0, watch=not-started） |
| AI Quality Gate | AI | **PASS**（15 項目すべて PASS、R2） |
| `approve`（人間承認） | 人 | `ha_mwukiolq_abf2a8e3e813`、`claudeos/human-approval=success`。別の head では `STALE_HEAD` で無効になることを確認 |
| ClaudeOS Merge Executor（dry-run） | AI | REFUSED（施行フラグ無効・ruleset が 2 context を未要求。設計どおり） |
| マージ | 人 | 画面からマージ（`63449b3`）。承認した `1d87dab` と内容が同一であることを確認 |

### 実機で分かった `/ship` の注意点

| 現象 | 原因 | 対処 |
| --- | --- | --- |
| 起動直後の 1 回目の入力が `Nothing started` になる | 起動時の SessionStart フックと重なり、人の入力と判定されないとみられる（**推測**） | `Async hook SessionStart completed` の表示を待ってから入力する。出たら同じ行をもう一度入力する |
| `claude` を起動すると一覧画面（Agent View）が開き、そこから送った `/ship` は `start /ship yourself by typing it in an interactive session` で止まる | ユーザー設定 `~/.claude.json` の `defaultToAgentsView=true`。一覧から送った指示はバックグラウンドセッションになり、`/ship` は動かない（公式仕様） | `claude "こんにちは"` のように最初の一言を付けて起動すると通常の会話画面になる（公式）。設定を戻すなら通常画面で `/config defaultToAgentsView=false` |
| 止まったバックグラウンドセッションが一覧に残る | 上と同じ | `claude stop <id>` で止める。完了済みの行は選ばずに `Esc` で抜けてよい |
| `/ship` が「watch できない。レビューだけ行う」と表示する | ユーザー設定 `remoteControlAtStartup=true`。リモート経由の入力を人の入力と区別できないため（公式の表示） | レビューと署名の練習ならこのままでよい。watch も使うなら `/rc` で Disconnect してから実行（auto-merge 有効のリポジトリでは推奨しない） |
| 起動しただけで `heartbeat.json` と `.claude/claudeos/data/.heavy-sync.stamp` が作られる | ClaudeOS のフック | `/ship` は未コミット変更をコミットし得るため、練習用 clone では `.git/info/exclude` に 2 行を足して除外する |
| 練習用 clone で `/ship` が作業ツリーを直す | レビューのみモードでも、本当の問題は作業ツリーで直す（公式の表示。コミット・push・コメントはしない） | 差分を確認し、取り込むなら PR 側にコミットする。取り込み後は練習用 clone の変更を `git restore` で戻す |

### 署名の対象について

`/ship` のレビューは修正前の `b229229` に対して行い、署名と承認は指摘を反映した `1d87dab` に対して行った。
`ship-attest` は head に紐づくため、修正後の head で署名し、`--notes` にレビュー時の head と反映の事実を残した。
レビューした head と署名した head が異なる場合は、この経緯を必ず notes に書く。
