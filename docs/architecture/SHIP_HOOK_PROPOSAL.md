# 承認事項 #8: PreToolUse(Bash) フックと /ship watch の両立案（提案・未適用）

状態: 2026-11-24 調査・提案のみ。**`.claude/settings.json`・テンプレート・フック本体は変更していない。**

## 1. 問題

公式仕様（[ship-command-troubleshooting](https://code.claude.com/docs/en/ship-command-troubleshooting.md) §A tool, rule, or hook blocks a watch）:

> A watch ... doesn't start where a project's hook could approve commands:
> The project sets a hook that could approve commands, for example a `PreToolUse` or `PermissionRequest` hook on shell commands in the checkout's `.claude/settings.json`

本リポジトリの `.claude/settings.json` は `PreToolUse` / `matcher: "Bash"` で `pre-commit-gate.js` を登録している
（`"if": "Bash(git commit *)"` で git commit に絞っているが、公式条件は「シェルコマンドに対する PreToolUse フックが **ある**こと」で、`if` による絞り込みを除外条件としていない）。
`bin/ship.sh capability` もこれを唯一の watch 阻害要因（`settings.project.hooks=fail`）として報告している（gh は承認 #9 で解消済み）。

## 2. 調査で分かった事実（実測 2026-11-24）

| 事実 | 確認方法 | 意味 |
| --- | --- | --- |
| フックが呼ぶ `scripts/lint/lint-and-fix.js` は、本リポジトリで **「no supported linter detected — skip」** | 実行 | 対応 linter は ESLint / ruff のみ。本リポジトリ（bash + Node、shellcheck）は対象外で、lint は**何も検査していない** |
| `package.json` に `test:quick` が無い | `jq` | テスト部分も**実行されない** |
| `reports/lint-summary.json` は生成されない | 実行 | ブロック条件（errors > 0）は成立し得ない |
| フック内部は fail-soft。`CLAUDEOS_SKIP_PRECOMMIT=1` と `--no-verify` で迂回できる | ソース | 強制力のあるゲートではない |
| 同フックを使うのは `Claude-StartUpTools-New-Linux` と `Codex-StartUpTools-New-Linux` の 2 件だけ | `~/Projects/*/.claude/settings.json` | 配布影響は小さい |
| git の pre-commit フックは未設定（`core.hooksPath` なし・`.git/hooks` は sample のみ） | `git config` / `ls` | 代替先は空いている |
| 実際の品質ゲートは `npm run lint`（shellcheck）・`npm test`・Local Quality Engine・CI `linux-validate` | — | フックを外しても品質ゲートは失われない |

**結論: 本リポジトリでは、このフックは現状どの検査も行っておらず、watch を止める副作用だけがある。**
ただし本番の自動化基盤の設定（`.claude/settings.json` = R4）であり、フックの存在が他の運用（統計・監査）に使われていないかも含め、人間の判断とする。

## 3. 案

| 案 | 内容 | watch | 品質 | 影響範囲 | ロールバック |
| --- | --- | --- | --- | --- | --- |
| **A（推奨）** | 本リポジトリの `.claude/settings.json` から PreToolUse(Bash) の pre-commit-gate を外し、同等以上の検査を **git の pre-commit フック**（`.githooks/pre-commit` + `git config core.hooksPath .githooks`）で行う。中身は実際に効く `shellcheck -S error`（変更された `.sh` のみ）と `bash -n` | ✅ 始まる（watch 中の Claude のコミットは `core.hooksPath=/dev/null` 付きで git フックを通らない＝公式仕様。人間・通常セッションのコミットには効く） | 現状（実質検査なし）より**向上** | 本リポジトリのみ。テンプレート配布先は不変 | 設定 1 行を戻す |
| B | テンプレート（`Claude/templates/claude/settings.json`）からも外し、配布先 2 件にも反映 | ✅ | 配布先でも ESLint/ruff を持つプロジェクトでは検査が減る（現状 2 件とも該当なし） | 2 リポジトリ | テンプレートを戻して再配布 |
| C | フックを残し、`/ship` を使うときだけ別 checkout（フック無しの設定）で実行する | ✅（別 checkout のみ） | 変化なし | 運用手順のみ | 不要 |
| D | 現状維持（watch を使わず `/ship` のレビューだけ使う） | ❌ | 変化なし | なし | 不要 |

### 案 A の注意点（隠さない）

- watch 中の Claude のコミットは git フックを通らない（公式仕様）。したがって watch のコミットの品質は、**Local Quality Engine（隔離実行）と CI** が担う。これは ClaudeOS の設計（品質判定は自己申告ではなく独立検証）と一致する。
- 外すのは本リポジトリの設定だけ。ユーザー設定の `kensan-auto-merge-guard.py`（グローバル PreToolUse）は残る。公式仕様の阻害条件は「checkout の `.claude/settings.json`」のため、グローバル設定は watch を止めない（ただし watch 中に Claude Code 自身が実行する gh/git にはグローバルフックも効かない — `SHIP_SECURITY_MODEL.md` §5）。
- 本変更は R4（`.claude/settings.json`・hooks）なので、通常 PR で人間承認後に適用する。

## 4. 案 A の差分案（未適用）

`.claude/settings.json`（`hooks.PreToolUse` の該当要素を削除。他のフックは不変）:

```diff
-    "PreToolUse": [
-      {
-        "matcher": "Bash",
-        "hooks": [
-          { "type": "command", "command": "node \"${CLAUDE_PROJECT_DIR}/.claude/claudeos/scripts/hooks/pre-commit-gate.js\"",
-            "if": "Bash(git commit *)", "continueOnBlock": true, "timeout": 240, "statusMessage": "pre-commit gate: lint / test:quick" }
-        ]
-      }
-    ],
```

`.githooks/pre-commit`（新規）:

```bash
#!/usr/bin/env bash
# 変更された .sh だけを shellcheck -S error と bash -n で検査する (npm run lint と同じ重大度)
set -euo pipefail
mapfile -t files < <(git diff --cached --name-only --diff-filter=ACMR -- '*.sh')
(( ${#files[@]} )) || exit 0
for f in "${files[@]}"; do bash -n "$f"; done
command -v shellcheck >/dev/null && shellcheck -S error "${files[@]}"
```

適用手順（人間承認後）: 上記 2 ファイルの PR → マージ後に各 clone で `git config core.hooksPath .githooks` → `bin/ship.sh capability` で `settings.project.hooks=ok` と `overall=available` を確認。
