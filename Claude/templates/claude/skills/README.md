# 📦 Claude/templates/claude/skills — 配布スキルテンプレート

登録プロジェクトの `.claude/skills/` へ配布される Claude Code スキルの正本。
`lib/template-sync.sh` がプロジェクト起動前に配布する。

## 配布規則

- 配布形式: `<skill名>/SKILL.md`（Claude Code のスキル自動発見は
  「ディレクトリ + SKILL.md + YAML frontmatter」が条件。flat な .md は認識されない）
- 配布先: `<project>/.claude/skills/<skill名>/SKILL.md`
- **存在しない場合のみ配布**（プロジェクト側のカスタマイズを保護し、上書きしない）
- 配布対象スキルは `lib/template-sync.sh` の `template_sync__apply` 内リストで管理する

## 現在の配布スキル

| スキル | 用途 |
|---|---|
| `verify-app` | 変更後の検証ループ（lint → typecheck → test → build を PASS まで反復） |

## スキルを追加するには

1. このディレクトリへ `<skill名>/SKILL.md` を作成する（frontmatter の `name` / `description` 必須。
   `description` には「何をするか」と「いつ使うか」の両方を書く）
2. `lib/template-sync.sh` の skills 配布リストへ `<skill名>` を追加する
3. `tests/bats/unit/template-sync.bats` へ配布・保護テストを追加する
4. `npm run test:bats` で検証する

参考: [Building verification loops in Claude Code with skills](https://claude.com/blog/building-verification-loops-in-claude-code-with-skills)
