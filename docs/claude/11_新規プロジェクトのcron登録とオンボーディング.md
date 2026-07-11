# 11. 新規プロジェクトの cron 登録とオンボーディング

> 🎯 **このドキュメントの目的**
> 「これから `/home/kensan/Projects` 配下に登録するプロジェクト」が、Claude（CTO 自律開発）によって
> **確実に・週次で実行される**までの導線を正本化する。既存プロジェクトの実行経路を cron へ一本化した
> 対応（2026-06-17）の続きであり、未来のプロジェクトにも同じ確実性を担保するための運用手順書。

---

## 🧭 背景: なぜ cron が「実行の正本トリガー」なのか

以前は実行トリガーが **supervisor デーモン** に依存していた。supervisor は健全性ガードを持ち、
`blocked_issues` が非空（実機待ち等で停止中の Issue がある）だと **セッションを起動せず halt** する。
このため「ブロック中の Issue を 1 つ抱えただけで、その他の開発が一切進まない」状態が起き得た。
これが「🤖 [supervisor] の存在が実行を邪魔している」と観測された正体である。

🔑 **cron-launcher (`~/.claudeos/cron-launcher.sh`) は supervisor のガードを一切参照しない。**
`blocked` ガードも daily-cap も通らずに `claude` セッションを起動するため、cron 経路に寄せることで
「ブロック Issue があっても他の開発は前進する」状態を機械的に担保できる。

| 経路 | blocked ガード | daily-cap | 主従 |
|---|---|---|---|
| supervisor (`bin/autonomy.sh start`) | ⛔ halt する（`halt_on_blocked=true` 時） | あり | 補完 |
| **cron (`cron-launcher.sh`)** | ✅ 参照しない | なし | **主** |

> supervisor 側でブロック停止を解除したいだけなら、`state.json` に
> `"supervisor": { "halt_on_blocked": false }` を設定する opt-out も用意されている（PR #44）。
> ただし `security_critical > 0` は opt-out 不可で**常に halt**する（非対称フェイルセーフ）。
> 詳細は `lib/supervisor.sh` の `sup__abnormal_reason` 第3引数を参照。

---

## 🧩 プロジェクトが「確実に実行される」までの 2 段階モデル

新規プロジェクトの確実な実行には、**性質の異なる 2 段階**を両方満たす必要がある。
ここを混同すると「メニューには出るのに、いつまで経っても自動で動かない」状態になる。

```
段階1: 登録（可視化）        段階2: トリガー（起動）
  .git があるフォルダ    →     cron スロットが割り当てられている
  = config_project_list に載る   = 週次で cron-launcher が起動する
  ✅ git 化を明示実行する          ⚠️ bulk-register を明示実行する必要がある
```

### 段階1: 登録（可視化）— 🟢 明示

`/home/kensan/Projects` 配下に `.git`（ディレクトリまたは worktree/submodule のファイル）を持つフォルダは、`config_project_list`
（`lib/config-loader.sh`）が L1 メニュー / cron / autonomy の **全 3 経路**で候補として列挙する。

- **新規フォルダの git 化**: 通常の `start.sh` は高速起動と不要ログ抑制を優先し、自動 `git init` は行わない。
  必要な場合のみ config の `.autoInitProjects=true` を設定すると、`bin/menu.sh` の実起動（`menu` 経路）時に
  `project_autoinit_scan`（`lib/project-autoinit.sh`）が `.git` 未保有フォルダを検知し、
  `git init` + `CLAUDE.md` テンプレ配置 + 初期 commit を実行する。冪等・非破壊・ローカル限定
  （GitHub repo 作成等の外部操作はしない）。`--render`（テスト描画）経路では実行しない。
- 自動除外: 本ツール repo 自身（`CCSU_ROOT`）、および `config/config.json` の `localExcludes` に列挙したフォルダ。
- **実行グループ限定（`projectGroups`）**: `config/config.json` の `projectGroups` にグループフォルダ名を
  列挙すると（例 `["Mirai-DX-Project"]`）、`config_project_list` は projects 直下の全走査を
  やめ、**その各グループ配下の Git リポジトリのみ**を `グループ名/サブ名` 形式で列挙する（L1 メニュー /
  cron / autonomy 共通）。グループ自身が `.git` を持っていても無視し配下を対象にする。L1 は
  「①グループ選択 → ②配下から選択」の 2 段階 UI になり、`autoInitProjects` もグループ配下のみを対象に
  する（グループフォルダを毎回 git init して単独 repo 化する退行を防止）。**グループが 1 件のみの場合は
  ①グループ選択を省略して配下一覧を直接表示**する（実質 1 段階。`0`/`q` はグループ選択へ戻らず終了）。
  空配列（既定）なら projects 直下全体が対象。

> ⚠️ **重要**: auto-init が完了しても、それは段階1（可視化）に過ぎない。
> **cron スロットは自動では付かない。** 段階2を必ず実施すること。

### 段階2: トリガー（起動）— 🟡 明示実行が必要

cron スロットの割り当ては `bin/cron-schedule.sh bulk-register` が担う。これは**冪等**で、
既に登録済みのプロジェクトは `(登録済み → skip)` として飛ばし、未登録のものだけ新規に追加する。

```bash
# まず DRY-RUN で割り当て計画を確認（--apply なし）
bash bin/cron-schedule.sh bulk-register --start 6 --spacing 5 --duration 300 --dow 1,2,3,4,5,6

# 計画に問題なければ --apply で実登録（登録済みは自動 skip）
bash bin/cron-schedule.sh bulk-register --start 6 --spacing 5 --duration 300 --dow 1,2,3,4,5,6 --apply
```

- `--start 6 --spacing 5 --duration 300`: 06:00 を起点に 5 時間間隔（= 1 セッション 300 分と重複しない最小間隔。`--spacing` 省略時は duration から自動導出）。
- `--dow 1,2,3,4,5,6`: 月〜土。0 を加えると日曜も使う。
- 未登録のみ対象にしたい場合は `--unmanaged-only`（cron 登録済み / supervisor 管理下を除外）。
- 登録上限は `config.json` の `cron.maxProjectsPerDay=2` / `cron.maxDurationMinutes=300`。3件目/日と300分超は拒否する。
- `run-now` / `launch --project` は cron 登録済みプロジェクトだけ実行できる。未登録プロジェクトの単発実行は禁止。
- 利用クレジット枯渇時は `bulk-register --apply` と `launch --all --yes` を使わず、登録済み対象の単発 `run-now --duration 60` へ落とす。

---

## 📐 cron スロットの容量天井（12 枠）

`bulk-register` は **1日2プロジェクト × 曜日 round-robin**で負荷分散する。割り当て式は
`hour = start_hour + slot * spacing`、`slot` は 0 または 1 のみ。1日3件目は作らない。

標準既定（`--start 6 --spacing 5 --duration 300 --dow 1,2,3,4,5,6`）の場合:

| スロット | 時刻 | 月 | 火 | 水 | 木 | 金 | 土 |
|---|---|---|---|---|---|---|---|
| slot 0 | 06:00 | ● | ● | ● | ● | ● | ● |
| slot 1 | 11:00 | ● | ● | ● | ● | ● | ● |

➡️ **容量 = 2 スロット × 6 曜日 = 12 枠**。13 番目以降のプロジェクトは
`⚠️ 容量超過(12件/週) → skip` で**黙って登録されない**ので、ログを必ず確認すること。

### ⏱ PR 番人マイクロループ（任意）

5 時間メガセッションの合間に open PR の CI 失敗・レビュー指摘対応だけを行う短時間ジョブ。
`--goal-type pr-babysit` を付けると cron 行に `CLAUDEOS_GOAL_TYPE_OVERRIDE=pr-babysit` が
前置され、`goals/pr-babysit.md` の限定 /goal（新規開発禁止・stop after 8 turns・早期終了）で起動する。

```bash
# 例: 毎日 14:30 に 30 分だけ PR の面倒を見る
bash bin/cron-schedule.sh add --project <NAME> --time 14:30 --dow 1,2,3,4,5,6 --duration 30 --goal-type pr-babysit
```

- state.json の `goal_type` は変更しない（そのセッション限りの上書き）
- 番人エントリも `cron.maxProjectsPerDay=2` の枠を消費する点に注意（メインスロットと同日に置く場合は空き枠を確認）

### 🔧 12 枠を超えて登録したいとき

| 方法 | コマンド例 | 容量 | トレードオフ |
|---|---|---|---|
| 日曜も使う | `--dow 0,1,2,3,4,5,6` | 14 枠 | 週 7 日稼働になる |
| 優先度で間引く | `localExcludes` に低優先度 repo を追加 | 可変 | 実行対象を減らす |

> 12 枠は「1日2プロジェクト・各5h」を守る運用上限。プロジェクト数が増え続ける場合は、
> 優先度の低いプロジェクトを `localExcludes` で間引くか、週次ローテーションを手動で組み替える。

---

## 🧹 localExcludes による不要フォルダの除外

`/home/kensan/Projects` 配下には、製品ではないツール repo・バックアップ・アーカイブ・純インフラ等、
**自動開発の対象にしたくない git フォルダ**が混在し得る。これらを `config_project_list` から外すのが
`config/config.json` の `localExcludes`（gitignored のローカル正本。template は空配列）。

```jsonc
// config/config.json （ローカル限定・git 管理外）
"localExcludes": [
  "kensan",                              // 純インフラ
  "ClaudeCode-StartUpTools-New-Backup",  // バックアップ
  "Project-Archieve",                    // アーカイブ
  "Codex-StartUpTools"                   // 別ツール repo（製品ではない）
  // ...本物のプロジェクト（state.json 有 or auto-init 済 git repo）は外さない
]
```

🔑 **新規フォルダを追加したら、まず「これは開発対象か / 除外対象か」を判断する。**
除外対象なら `localExcludes` に足してから（段階2の前に）`bulk-register` する。そうしないと
不要フォルダにも cron 枠を消費させてしまい、12 枠の天井を無駄に圧迫する。

---

## 🚦 意図的に「動かさない」プロジェクトの扱い

特定プロジェクトを**意図的に停止**しておきたい場合（例: 仕様再検討で一時停止）:

- **cron に登録しない**（`bulk-register` 後に該当行を `crontab -e` で削除、または最初から対象外にする）。
- supervisor 側も起動しない。`halt_on_blocked` も**設定しない**（設定しないことが「触らない」意思表示）。

> 📌 実例: `Construction-DX-OS` はユーザー指示により一時停止中。cron エントリを持たず、
> `state.json` に `supervisor` セクションを**置かない**ことで pause を表現している。
> 自動再開させないため、bulk-register の対象からも明示的に外している。

---

## ✅ オンボーディング チェックリスト（新規プロジェクト登録時）

```bash
# 1. フォルダが git 化されているか（auto-init 済 or 手動 git init）
ls -d /home/kensan/Projects/<NAME>/.git

# 2. config_project_list に載っているか（除外されていないか）
bash -c 'source lib/config-loader.sh; config_project_list | grep <NAME>'

# 3. 除外対象なら localExcludes に追加（config/config.json）

# 4. cron スロットを割り当て（DRY-RUN → --apply）
bash bin/cron-schedule.sh bulk-register --start 6 --spacing 5 --duration 300 --dow 1,2,3,4,5,6        # 計画確認
bash bin/cron-schedule.sh bulk-register --start 6 --spacing 5 --duration 300 --dow 1,2,3,4,5,6 --apply # 実登録

# 5. cron に入ったか確認
crontab -l | grep 'project=<NAME> '

# 6. （任意）次回起動を待たず即実行（cron 登録済みのみ）
bash bin/cron-schedule.sh run-now --project <NAME>
```

🔑 **段階2（手順4）を忘れない**こと。git 化はフォルダを「見える」ようにするだけで、
「動く」ようにするのは `bulk-register` の役目。この 2 段階を両方満たして初めて、
新規プロジェクトも既存と同じ確実性で自律開発が回り始める。

---

## 🔗 関連ドキュメント

- `docs/claude/09_headless運用とフォールバック.md` — cron-launcher の headless 実行とフォールバック
- `docs/claude/08_heartbeat-watchdog-cron設定手順.md` — cron 起動の死活監視
- `docs/claude/12_Claude_Design連携.md` — Claude Design / Claude Code 双方向同期と `/design-sync-check` 手順
- `docs/claude/13_Claudeモデルルーティング.md` — Opus 4.8 / Sonnet 4.6 の自動使い分け
- `Claude/templates/claudeos/docs/auto-merge-protocol.md` — 条件付き自動 merge の正本手順
- `Claude/templates/claudeos/goals/safe-auto-merge.md` — `goal_type=safe-auto-merge` で選択する安全自動 merge プロンプト
- `CLAUDE.md`（リポジトリ直下）— プロジェクト方針・自動 merge 条件・CTO 自律開発境界
