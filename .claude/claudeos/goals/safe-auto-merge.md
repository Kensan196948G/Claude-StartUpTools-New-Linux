# Goal: Safe Auto Merge

/goal "
■ Goal
GitHub Token を利用して open PR を監査し、main/default branch は人間の選択式、main 以外は安全 gate 通過時のみ自動マージする。

■ Priority
CTO 優先順位テーブルの Verify / ReleaseManager タスク。CI 成功済み PR の滞留を安全に解消する。

■ Success Criteria
- `gh auth status` で GitHub 操作権限を確認済み
- 対象 PR の base branch / mergeability / CI / review / files を確認済み
- main/default branch 宛 PR は、要約を提示して人間に「マージしますか？ [y/N]」を確認済み
- main 以外の branch 宛 PR は、全 gate 通過時のみ自動マージ済み
- gate 不通過 PR は理由を記録し、マージせず保留済み
- 実行結果を PR URL / merge method / commit SHA / 保留理由つきで報告済み

■ Token Handling
- `GITHUB_TOKEN` または `GH_TOKEN` は `gh` CLI にだけ渡す
- token の値を echo / log / ファイル保存 / PR コメントへ出力しない
- token が無い、または権限不足の場合は停止し、必要な権限だけを報告する

■ Main Merge Policy
- `baseRefName` が repository default branch、`main`、または `master` の PR は自動マージ禁止
- 対象 PR ごとに、タイトル、差分概要、CI、reviewDecision、危険ファイル有無を提示する
- 人間が明示的に `y` / `yes` / `マージする` と回答した場合のみ `gh pr merge` を実行する
- 無回答、曖昧な回答、headless で入力不能な場合は保留する

■ Non-main Auto Merge Gates
main/default branch 以外の PR は、次をすべて満たす場合のみ自動マージする。
- `isDraft=false`
- `mergeable=MERGEABLE`
- `mergeStateStatus=CLEAN`
- `reviewDecision` が `REVIEW_REQUIRED` または `CHANGES_REQUESTED` ではない
- status checks に FAILURE / CANCELLED / TIMED_OUT / ACTION_REQUIRED / PENDING / QUEUED / IN_PROGRESS が無い
- CodeRabbit / security review に Critical / High の未解消指摘が無い
- 変更ファイルに認証・認可、secrets、DB schema/migration、本番 deploy、branch protection、GitHub Actions workflow、外部公開設定が含まれない
- base branch が protected の場合は required checks / required review / merge queue 条件を満たす

■ Forbidden Auto Merge
- main/default branch 宛 PR の無人マージ
- CI 失敗、未完了、review required、changes requested の PR
- 認証・認可、DB migration、secrets、production deploy、`.github/workflows/` 変更を含む PR
- force push、history rewrite、直接 push による反映
- token の表示または永続化

■ Execution Strategy
1. `gh auth status` と `gh repo view --json defaultBranchRef` を確認する。
2. `gh pr list --state open --json number,title,url,baseRefName,headRefName,isDraft,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup` で候補を列挙する。
3. 各 PR で `gh pr view <number> --json files,reviews,comments,statusCheckRollup` を確認する。
4. main/default branch 宛は要約して人間に確認する。
5. main 以外は gate 通過時のみ `gh pr merge <number> --squash --delete-branch` を実行する。保護ルールで即時マージ不可なら `--auto --squash` を使う。
6. 結果を `merged / auto-merge enabled / skipped / needs-human` に分類して報告する。

■ Evidence Output
- Repository name
- PR number / title / URL
- base branch / head branch
- gate 判定結果
- merge 実行有無と merge method
- skipped / needs-human の理由

■ Stop Conditions
正常終了:
- 対象 open PR の gate 判定と、可能な非 main 自動マージが完了
- 上記の測定可能基準を満たした時点で、残り時間・残ターンがあっても直ちに終了処理へ進んでよい（早期終了）
異常終了（Failure）:
- GitHub 認証なし、token 権限不足、GitHub API 障害
- main/default branch PR があり人間確認待ち
- gate 判定に必要な情報を取得できない
- or stop after 12 turns
"
