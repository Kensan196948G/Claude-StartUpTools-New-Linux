# Auto Merge Protocol — main 選択式 / 非 main 条件付き自動

## 概要

GitHub Token を利用した PR マージは、base branch によって扱いを分ける。

| base branch | 方針 |
|---|---|
| repository default branch / `main` / `master` | 人間の選択式。明示承認なしにマージしない |
| 上記以外の branch | gate 全通過時のみ自動マージ可 |

token は `gh` CLI の認証にだけ使い、値を表示・保存・転記しない。

## 必須 gate

全 PR で次を確認する。

- `gh auth status` が成功する
- `isDraft=false`
- `mergeable=MERGEABLE`
- `mergeStateStatus=CLEAN`
- CI / status checks に failure, cancelled, timed out, pending, queued, in progress が無い
- `reviewDecision` が `REVIEW_REQUIRED` または `CHANGES_REQUESTED` ではない
- CodeRabbit / security review に Critical / High の未解消指摘が無い

## 自動マージ禁止条件

非 main branch 宛でも、次を含む PR は自動マージしない。

- 認証・認可の変更
- secrets / token / credential の追加・変更
- DB schema / migration の変更
- production deploy / 外部公開設定の変更
- `.github/workflows/` または branch protection / ruleset 変更
- force push / history rewrite / direct push が必要な状態
- gate 判定に必要な情報が取得できない状態

## CTO 実行手順

```bash
# 1. 認証確認。token 値は表示しない。
gh auth status

# 2. default branch を確認。
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')

# 3. open PR を列挙。
gh pr list --state open \
  --json number,title,url,baseRefName,headRefName,isDraft,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup

# 4. PR 詳細を確認。
gh pr view <PR番号> --json files,reviews,comments,statusCheckRollup
```

### main/default branch 宛

1. PR 番号、タイトル、URL、CI、review、危険ファイル有無を要約する。
2. 人間に確認する。

```bash
read -r -p "main/default branch にマージしますか？ [y/N] " ans
```

3. `y` / `yes` / `マージする` の明示回答がある場合だけ実行する。

```bash
gh pr merge <PR番号> --squash --delete-branch
```

### main 以外の branch 宛

gate 全通過時のみ実行する。

```bash
gh pr merge <PR番号> --squash --delete-branch
```

保護ルールや merge queue により即時マージできない場合だけ、条件が満たされていることを確認して auto-merge を設定する。

```bash
gh pr merge <PR番号> --auto --squash
```

## 結果報告

最後に PR ごとに分類して報告する。

- `merged`: マージ済み
- `auto-merge enabled`: GitHub auto-merge 設定済み
- `needs-human`: main/default branch など人間確認待ち
- `skipped`: gate 不通過。理由を明記

## 注意事項

- `main` / default branch の無人マージは禁止
- token の値をログ、ファイル、Issue、PR コメントへ出力しない
- CI 未通過・未検証・review required の PR はマージしない
- 自動マージ対象は、通常の開発 branch 間 PR または検証用 branch への統合に限定する
