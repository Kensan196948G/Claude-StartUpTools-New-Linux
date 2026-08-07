# CHANGELOG

## [Unreleased]

### Added

- 🆕 Managed Agents 2026-08 新機能 4 点の取り込み方針を PoC 手順書へ追加
  （2026-08-08 ユーザー指示・docs/claude/07 §7 新設）。
  - 対象: 💰 セッション予算（`budget.max_list_cost`・再開時必須適用）、
    🌍 推論実行場所（`inference_geo`・更新時は全置換に注意）、
    📚 リポジトリスキル自動読み込み（`<name>/SKILL.md` 形式は PR #87 で移行済み = 適合）、
    🧠 アドバイザー（roster へ `advisor_20260301` エントリ・budget とセット導入）。
  - 実在検証: anthropic-sdk-python v0.121.0（2026-08-07）の型定義 diff で 4 機能とも確認。
    流布情報の訂正 3 点（`budget_reached` イベントは存在せず `session.usage` で追跡・
    `inference_geo` は replace-all・advisor は roster 1 エントリ形式）を明記。
  - `config/managed-agents.json.template` へ記録用キー
    `sessionBudget` / `inferenceGeo` / `advisorModel` を additive 追加（読み手コード無し）。
  - live 検証は PoC sandbox bug（docs/claude/07 §6-3・Anthropic case 返信待ち）と
    課金 churn 防止方針により **BLOCKED**。コード追加禁止方針（docs/claude/09）は維持。
- 📡 クロスセッションメッセージング基盤を全起動経路へ統合（2026-08-08 ユーザー指示）。
  - 全起動経路（`lib/tmux-runner.sh`・`bin/start-claude.sh` の TUI/headless/BG・
    `cron-launcher.sh` の headless/TUI/no-tmux）で claude 起動時に
    `--name claudeos-<プロジェクトキー>[-<役割>]` を自動付与。`/list-agents` 上で
    安定した宛先名になり、CTO/Backend/Frontend/QA の役割別セッション間通信が可能に。
  - 命名ヘルパー `ccsu_claude_session_name` / `ccsu_claude_supports_name` を
    `lib/common.sh` へ追加。起動前に `claude --help` で `--name` 対応を probe し、
    未対応バージョン（v2.1.196 未満）には付与しない（起動失敗を防止）。
    safe-mode 診断起動には意図的に付与しない。
  - 役割サフィックスは `CCSU_SESSION_ROLE`（StartUpTools 経路）/
    `CLAUDEOS_SESSION_ROLE`（cron-launcher 経路）で opt-in。
    `CCSU_SESSION_NAME=0` / `CLAUDEOS_SESSION_NAME_ENABLED=0` で無効化可能。
  - 通信統制: CLAUDE.md §27「クロスセッションメッセージング通信規約」を新設
    （メッセージは人間の承認を代替しない・本番公開/Secrets/課金/破壊的削除/
    main 直接 push/PR merge はメッセージだけを根拠に実行しない）。
    4 コピー（ルート・`Claude/`・テンプレート・グローバル）へ md5 一致で配布。
  - `Claude/templates/claude/settings.json` の `requiredMinimumVersion` を
    `2.1.224`（クロスセッションメッセージング必須版）へ更新。
  - 新規文書 `docs/claude/19_クロスセッションメッセージング.md`（前提条件・命名・
    4役割トポロジ・受信ポリシー方針・監査・残課題）と `docs/claude/04_環境変数.md` の
    4 変数追記。テスト `tests/bats/unit/session-name.bats`（14 件）を追加。

### Fixed

- 🎯 新 `/goal` 統合プロンプトが Claude Code 本体の goal 条件 4,000 文字制限を超過し
  起動失敗する問題（`Goal condition is limited to 4000 characters (got 4016)`）を修正。
  - 本文を意味保持の外科的短縮 7 箇所で 4,014 → 3,943 文字へ圧縮
    （引用符込み 3,945 文字・余裕 55 文字）。丁寧体と指示内容は不変。
  - 対象: `Claude/templates/claude/START_PROMPT.md` と CLAUDE.md §25（計 5 コピー +
    Git 管理外のグローバル `~/.claude/CLAUDE.md`）。全コピー md5 一致を検証済み。
  - 再発防止: `tests/bats/unit/goal-inject.bats` へ「/goal 本文 4,000 文字以内
    （引用符込み）」「START_PROMPT.md と CLAUDE.md §25 の本文一致」の 2 テストを追加。

### Changed

- 📂 メニューの起動セクションを複数実行グループ対応へ変更（2026-08-06 ユーザー指示）。
  - ヘッダーの実行グループ表示を旧カンマ結合 1 行から「▸ 実行グループ (N): 名前」の
    番号付き複数行へ変更（配列の並び順 = 番号）。
  - `projectGroups` 設定時は L1..Ln をグループごとに動的生成し、各行へフルパスを表示。
    L<n> はそのグループ配下のサブプロジェクト選択へ直結（グループ選択を省略）。
  - `launcher__select_project` に第 2 引数 `group` を追加（既存の単一グループ
    スキップ機構へ preset として写像・0/q は即終了）。存在しないグループ指定は
    警告して通常のグループ選択へフォールバック。
  - S1（バックグラウンド起動）は従来どおり「グループ選択 → 配下選択」の 2 段階を維持。
    `projectGroups` 未設定時は L1 単独のフラット選択（後方互換・L2 以降は無効入力）。
  - 対象: `bin/menu.sh`、`lib/launcher-common.sh`、`config/config.json.template`
    （コメント）、`docs/claude/11`、`menu.bats` / `launcher-common.bats`。
- 🧠 既定 AI モデルを Sonnet 5 (max) から **Opus 5 (`claude-opus-5`・Recommended)** へ変更
  （2026-08-06 ユーザー指示）。
  - 全タスクが Opus 5 ルートへ。effort は 2 階層を自動適用:
    高リスク（security/architecture/design/release/deploy/critical/incident/hotfix/
    pr-review/final-review/cto/plan）= `xhigh`、通常タスク = `high`（Opus 5 の recommended 既定）。
  - Sonnet 5 (max) は明示 opt-in のみ（task 文字列に `sonnet` を含めるか
    `CLAUDEOS_MODEL_KEY=sonnet`）。
  - 利用量バランス機構（5% 閾値の低利用モデル切替）は既定 OFF へ降格。
    新設 `modelRouter.balanceEnabled`（既定 `false`）または `CLAUDEOS_MODEL_BALANCE=1` で
    従来動作を復元可能。有効のままだと約半数のセッションが Sonnet へ流れ
    「既定 = Opus 5」と矛盾するため。
  - 対象: `lib/model-router.sh`、`config/config.json.template`、
    `Claude/templates/linux/cron-launcher.sh`（コメント）、`docs/claude/13`（全面改訂）、
    `docs/claude/11`、関連 bats テスト。
- 🤖 開発体制ポリシーを「毎 PR の Y/N マージ承認」から「品質ゲート条件付き自動マージ」へ全面変更。
  - CTO 代行への全面権限委譲（例外なし）。§16 の品質ゲート 8 条件
    （CI 全 PASS・Critical/High 脆弱性ゼロ・secret/PII 露出なし・additive migration のみ・
    高リスク変更非該当・PR 本文完備・production-safe 判定・head SHA 一致）成立時は
    追加確認なしで自動マージ〜本番デプロイ〜DevOps 安定化まで連続実行。
  - 人間の Y/N 判断は §17 Approval PR（DNS/custom domain・production Secrets・認証方式・
    破壊的 migration・課金影響等の高リスク変更）と品質ゲート未達時のみに限定。
  - Web サービスの本番基盤は Cloudflare (Pages/Workers) + Neon PostgreSQL。
    custom domain / サブドメインはデプロイ時点でユーザーへ入力または選択を要求
    （既定 URL `*.pages.dev` / `*.workers.dev` での先行リリースは自律実行可）。
  - 安定化完了後は「一旦終了」として最終報告を提示し、セッションは起動したまま
    次のプロンプト指示を待つ運用へ変更。
  - 対象: プロジェクト/正本/配布テンプレート計 5 コピーの `CLAUDE.md`、
    `Claude/templates/claude/START_PROMPT.md`（新 `/goal` 統合プロンプトへ差し替え）。
    グローバル `~/.claude/CLAUDE.md` も同一内容へ更新済み（Git 管理外）。
    組織ポリシー `/etc/claude-code/CLAUDE.md` の改訂案は scratchpad に作成済みで、
    ユーザーの sudo 適用後に完全有効化（適用まで旧ポリシーの Y/N ゲートが優先）。
- 🖥️ L1「ローカル即起動 (フォアグラウンド)」の一回 5 時間制限を撤廃し、既定を無制限へ変更。
  - 新設定 `supervisor.defaults.foregroundSessionMinutes`（`0` = 無制限、既定 `0`）。
    分数を区切りたい場合はこのキーか `start-claude.sh --duration` で指定する。
  - foreground は `CCSU_MAX_SESSION_MINUTES`（300 分）の分数上限チェック対象外へ
    （人間が対話する前提のため）。同時実行セッション数上限 (`CCSU_MAX_SESSIONS=4`) は維持。
  - S1 / cron / supervisor の自律実行は従来どおり 300 分ガードを維持（省クレジット運用）。
  - `duration=0` は GNU coreutils `timeout` の「0 = タイムアウト無効化」仕様で無制限として機能。
    background への `--duration 0` 指定は明示エラーで拒否。

### Added

- 🔁 検証ループのスキル化（Anthropic ブログ 2026-07-22 準拠、`docs/claude/18_検証ループ運用.md` 正本）。
  - `.claude/skills/` を `<name>/SKILL.md` ディレクトリ形式へ移行
    （flat `.md` は Claude Code のスキル自動発見対象外と実証・移行後に認識を確認）。
  - `/verify-startuptools` 新設: bash 構文・bats/node テスト・テンプレート整合性・
    正本/テンプレ同期・secret 確認を PASS まで反復する本リポジトリ固有の検証ループ。
  - 配布 starter スキル `verify-app` 新設（`Claude/templates/claude/skills/`）。
    `lib/template-sync.sh` が登録プロジェクトの `.claude/skills/` へ
    存在しない場合のみ配布（プロジェクト側カスタマイズ保護）。
  - claudeos `verification-loop` スキルをブログ準拠に改訂
    （4 起動形態 standalone / embedded / chained / on-every-PR、スキル化 6 ステップ、
    修正上限 → BLOCKED のループ規則。正本と配布テンプレートを同期）。

### Removed

- `bin/monitor-sessions.sh`（🎛️ コントロールセンター / `claudeos-monitor`）とそのテスト
  `tests/bats/unit/monitor-sessions.bats` を完全削除。監視・起動・Supervisor・介入を
  1 画面に統合する `MO` メニュー項目も撤去。
  - 代替: セッション状態監視は `libexec/watch-session.sh`（メニュー項15）、
    接続・介入は `tmux attach -t claudeos-<project>`、Supervisor 全適用は
    `bin/autonomy.sh start --all`。
  - 副作用: 同ファイルが内包していた `mon__agents_waiting()`（Managed Agents の
    `waitingFor` 可視化）も併せて消失。waitingFor は `claude agents --json` を直接参照する。

## [4.0.0-linux] - 2026-06-07

### Added

- Linux ローカル専用の Claude Code 起動経路。
- `/home/kensan/Projects` 配下の Git リポジトリ候補検出。
- `bin/autonomy.sh start --all` / `stop --all` による Supervisor 全適用。
- `bin/monitor-sessions.sh` の `[a]` 全監督、`[n]` 数字付き個別選択。
- CTO Claude 自律開発と人間最終決断の境界をテンプレートへ明記。
- Ubuntu CI、Bats、Node test、shellcheck。

### Changed

- 参照リポジトリから Linux 実行系を移植し、設定初期値を Linux 向けへ変更。
- 運用メニューの灰色表示を避けるため、互換色変数を白表示へ変更。
- README、docs、tests README、Source of Truth を Linux 版へ刷新。

### Removed

- `.ps1`、`.psm1`、`.bat` ファイル。
- SSH 接続、リモート配布、PTY bridge、旧Windows/PowerShell CI。
- Codex/Copilot 起動ドキュメントと旧フェーズ文書。
