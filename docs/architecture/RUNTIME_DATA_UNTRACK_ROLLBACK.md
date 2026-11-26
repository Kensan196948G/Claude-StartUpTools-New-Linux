# 影響分析とロールバック: 実行時データ 2 ファイルを Git 管理から外す（PR #242、R2）

状態: 2026-11-26。

## 1. 影響分析

- 対象は `.claude/claudeos/data/reasoning-bank.json` と `trust-score.json`。追跡を外し、`.gitignore` に追加する（`.heavy-sync.stamp` も追加）。コードの挙動は変えない。
- 読み取り側（`session-end.js`・`serve-dashboard.js`・`reasoning-bank.js`）は、欠落時に既定値で動作する（コードの読解）。
- **新しい clone にはこの 2 ファイルが存在しない**。学習データと信頼スコアは初期値から始まる。
- **既存の clone は pull でこの 2 ファイルが削除される**。未コミットの変更があると pull は中断する。残したい場合は pull の前にリポジトリ外へコピーし、`git checkout -- <2 ファイル>` の後に pull して、コピーを戻す（戻した後は ignore されるため差分にならない）。
- secret・DB・migration の変更はない。

## 2. ロールバック手順

1. 各 clone で現在の 2 ファイルをリポジトリ外へコピーする（revert の取り込みで古い内容に置き換わる可能性があるため）。
2. `git revert <マージコミット>` の PR を作り、通常の手順でマージする。追跡が戻り、内容は削除直前のコミット時点になる。
3. 必要なら、コピーした最新の内容を戻す。
