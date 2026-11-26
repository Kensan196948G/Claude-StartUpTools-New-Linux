# 影響分析とロールバック: 実行時データ 2 ファイルを Git 管理から外す（PR #242、R2）

状態: 2026-11-26。

## 1. 影響分析

- 対象は `.claude/claudeos/data/reasoning-bank.json` と `trust-score.json`。追跡を外し、`.gitignore` に追加する（`.heavy-sync.stamp` も追加）。コードは変えないが、下記のとおり表示値は変わる。
- 読み取り側（`session-end.js`・`serve-dashboard.js`・`reasoning-bank.js`）は、欠落時に既定値で動作する（コードの読解）。手順書 `roles/cto-build.md` の Trust Level 確認も読み取り側で、テンプレート側は欠落時に既定値を表示する。配布コピー `.claude/claudeos/roles/cto-build.md` は未同期。
- **本番の表示値が変わる**: リリース成果物は `git archive` で作るため、2 ファイルは含まれない。この変更を含む commit を昇格すると、`/api/health` と Mission Control の信頼スコアは、追跡されていた値（score 0.9、level 3、auto_merge_enabled true）から既定値（score 0、level 1、false）になる。
- **CI 実績は引き継がれない**: 新しい clone には CI 実績（`total_ci_runs` など）がないため、`session-end.js` の計算に CI 成功率は反映されず、score は低い値から始まる。
- **配布ワークフローの制限**: `blocked-events-update.yml` は `trust-score.json` が追跡されている前提のままで、有効にするとファイルがない場合に `git add` で失敗する（このリポジトリの `.github/workflows` には未導入）。
- **古いブランチ・commit への切り替えでデータが失われる**: git は ignore 対象の未追跡ファイルを警告なしで上書きする。この変更より前の commit を checkout すると古い追跡内容に置き換わり、戻ると削除される。切り替える前に 2 ファイルをリポジトリ外へコピーする。
- **新しい clone にはこの 2 ファイルが存在しない**。学習データと信頼スコアは初期値から始まる。
- **既存の clone は pull でこの 2 ファイルが削除される**。未コミットの変更があると pull は中断する。残したい場合は pull の前にリポジトリ外へコピーし、`git checkout -- <2 ファイル>` の後に pull して、コピーを戻す（戻した後は ignore されるため差分にならない）。
- secret・DB・migration の変更はない。

## 2. ロールバック手順

1. 各 clone で現在の 2 ファイルをリポジトリ外へコピーする（revert の取り込みで古い内容に置き換わる可能性があるため）。
2. `git revert <マージコミット>` の PR を作り、通常の手順でマージする。追跡が戻り、内容は削除直前のコミット時点になる。
3. 必要なら、コピーした最新の内容を戻す。
