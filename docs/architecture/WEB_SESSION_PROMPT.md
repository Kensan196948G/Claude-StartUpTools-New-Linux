# Web コンソール: セッション画面のプロンプト送信（高リスク機能）

`POST /api/session/prompt` は、公開画面（Cloudflare Access 配下）から**ホスト上で Claude に作業をさせる**機能です。
実質的にリモートコード実行に近いため、**既定で無効**とし、下記の条件をすべて満たしたときだけ動作します（fail-closed）。
導入は Approval PR（人間の明示承認）として扱います。

## 仕組み

- 停止中のプロジェクトに対し、ヘッドレス会話（`claude -p --output-format stream-json`）を **1 ターンずつ**進めます。
  稼働中のセッション（tmux の TUI や、自律実行の supervisor）へ「直接入力」するものではありません。
- 会話の系譜は Web 専用です。初回は直近の自律セッションを `--resume <id> --fork-session` で**分岐**して始め、以後は Web 専用の session_id
  （`~/.claudeos/web-prompt/<safe名>-<hash>.json`）を `--resume` します。自律実行の会話履歴（トランスクリプト）には書き込みません。
- 応答は NDJSON（`application/x-ndjson`）でストリーミングします。`claude` の出力のうち、ブラウザへ中継するのは
  許可リストのイベントだけです（`system/init`・`stream_event` の `text_delta`・`assistant` の本文と `tool_use` の名前・`result`）。
  **ツール結果（ファイル内容・コマンド出力）と `tool_use` の入力は中継しません。**
- 稼働中（supervisor / headless / tmux / foreground）のプロジェクトには送れません（409 `SESSION_RUNNING`）。
  Web 会話の実行中は、同じプロジェクトの起動も拒否します（409 `PROMPT_IN_PROGRESS`）。

## 有効化（サーバー側の環境変数）

| 変数 | 必須 | 内容 |
|---|---|---|
| `STARTUP_WEB_PROMPT_ENABLE=1` | はい | 有効化。未設定なら常に 403 `PROMPT_DISABLED` |
| `STARTUP_WEB_PASSWORD` | どちらか | Basic 認証のパスワード（設定されていれば、これで認証済みとみなす） |
| `CF_ACCESS_TEAM_DOMAIN` + `CF_ACCESS_AUD` | どちらか | Cloudflare Access の JWT（`Cf-Access-Jwt-Assertion`）を検証する。チームドメイン（`<team>.cloudflareaccess.com`）と、アプリケーションの AUD タグ |
| `STARTUP_WEB_ALLOWED_HOSTS` | 公開時 | 許可する Host（カンマ区切り。例: `claude-startuptools.mirai-dx-platform.com`）。**完全一致**のため、標準ポート（443）の公開ホストは**ポート無し**で登録する（ブラウザの Host にポートが付かないため）。loopback（`127.0.0.1` / `localhost` / `[::1]` の任意ポート）は常に許可 |
| `STARTUP_WEB_PROMPT_PERMISSION` | 任意 | 子 `claude` の権限モード（`auto` / `acceptEdits` / `plan` / `default`）。**既定は `acceptEdits`**。`auto` は明示したときだけ |
| `STARTUP_WEB_PROMPT_BUDGET_USD` | 任意 | 1 回あたりの予算上限（既定 2）。不正値は既定へ戻す（無効化されない） |
| `STARTUP_WEB_PROMPT_TIMEOUT_MS` | 任意 | 1 回あたりの時間上限（既定 600000）。不正値は既定へ戻す |
| `STARTUP_WEB_LAUNCH_REQUIRE_JWT` | 任意 | `1` で、**実起動**（`POST /api/startup/launch` と `apply-all` の `confirm: true`）に Cloudflare Access の JWT（メール付き）を必須にする。既定は無効（ローカル直アクセスの運用を壊さない）。Basic では代替できず、`CF_ACCESS_TEAM_DOMAIN` / `CF_ACCESS_AUD` が未設定なら実起動を拒否する（`AUTH_NOT_CONFIGURED`）。計画の表示（confirm 無し）と `dryRunOnly` は JWT 無しで使える。監査に実行者のメールを残す |
| `STARTUP_WEB_PROMPT_DAILY_MAX` | 任意 | 1 日あたりの送信回数の上限（既定 50）。翌日 0 時（サーバーのローカル時刻）にリセット |
| `STARTUP_WEB_PROMPT_DAILY_BUDGET_USD` | 任意 | 1 日あたりの累計予算の上限（既定 10 USD）。起動時に 1 回ぶんの予算を確保し、終了時に実コストで精算 |
| `STARTUP_WEB_PROMPT_ENV_PASS` | 任意 | 子 `claude` へ**追加で渡す**環境変数名（カンマ区切り）。allowlist と秘密判定の両方を越えるため、必要な名前だけを明示する |

認証が一切設定されていなければ、有効化していても 403 `PROMPT_AUTH_NOT_CONFIGURED` で拒否します。
`Cf-Access-Authenticated-User-Email` ヘッダの自己申告は信用しません（JWT の署名・`iss`・`aud`・`exp` を検証します）。

## ガード一覧

- 認証（上記）／ Host 許可リスト／ **Origin 必須かつ Host 一致**／ `Content-Type: application/json` のみ／ `Sec-Fetch-Site` が `same-origin|none` 以外なら拒否
  （DNS rebinding・CSRF 対策）。
- `confirm:true`（UI の確認ダイアログ）。これは**誤操作と自動送信の防止**であり、サーバー側の人間確認ではありません（認証済みの要求は自動化できます）。
- `dryRunOnly` では拒否。本文は 4000 文字まで・NUL 禁止。モデルは `auto|opus|sonnet|haiku` のみ。
- 同時 1 件。予算（`--max-budget-usd`）と時間の上限。クライアント切断・タイムアウト・サーバー停止で、**子プロセスをプロセスグループごと**停止します
  （ツールが起動した孫プロセスを残さない）。孫が stdout を握っていても、終了後 数秒でロックを解放します。
- 子プロセスへ渡す環境は **allowlist**（`PATH`・`HOME`・`USER`・`LANG`・`LC_*`・`XDG_*`・`TERM`・`TZ`・`TMPDIR`・プロキシ・CA 証明書・`CLAUDE_*`・`ANTHROPIC_*` など）で絞り、
  その上で秘密らしい名前（`ANTHROPIC_API_KEY`・`*TOKEN*`・`*SECRET*`・`*PASSWORD*`・`*_API_KEY`・DSN・DB 接続文字列 など）を更に除きます（二重の防御）。
  `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_AUTH_TOKEN` は claude 自身の認証のため残します。上記に無い名前が必要なら `STARTUP_WEB_PROMPT_ENV_PASS` で明示します。
  **渡らなくなる主な変数**: `SSH_AUTH_SOCK`・`GH_TOKEN` / `GITHUB_TOKEN`・`AWS_*`・`GOOGLE_*`・`KUBECONFIG` など（Bedrock / Vertex 構成の認証情報も `STARTUP_WEB_PROMPT_ENV_PASS` が必要）。
- **日次の上限**: 回数（既定 50）と累計予算（既定 10 USD）。`~/.claudeos/web-prompt/usage-YYYY-MM-DD.json` に記録し、プレビューと送信の両方で 429（`PROMPT_DAILY_LIMIT` / `PROMPT_DAILY_BUDGET`）で拒否します。
  使用量を記録できないとき（500 `USAGE_WRITE_FAILED`）や、使用量ファイルが破損していて読めないとき（429 `PROMPT_USAGE_UNREADABLE`）は、上限を守れないため送信しません（fail-closed。破損ファイルは削除すると復旧します）。
  claude を起動できなかった送信（`SPAWN_FAILED`）は、回数にも予算にも数えません。日付をまたぐ精算でも当日の記録は消えません（掃除は今日より古い日だけ）。
  複数のサーバープロセスが同じ `~/.claudeos/web-prompt/` を共有する構成では、使用量の読み書きにロックが無いため、上限をすり抜け得ます（単一プロセス前提）。
- **変更系 API 共通の検査**（`launch` / `stop` / `apply-all` / `plan` / `release-check`）: Host は loopback・IP リテラル・`STARTUP_WEB_ALLOWED_HOSTS` のみ（DNS rebinding 対策）、
  本文があるなら JSON のみ（415）、`Sec-Fetch-Site` が `same-origin|none` 以外は拒否。Origin は従来どおり「付いていれば Host と一致」（CLI からの直接呼び出しを壊さないため必須にはしない）。
  公開ホスト名（DNS 名）でアクセスする場合は `STARTUP_WEB_ALLOWED_HOSTS` への登録が必要です（未登録だと 403 `HOST_REJECTED`）。**この要件は変更系 API 全体に広がりました**（以前はプロンプト送信のみ）。
  比較は大文字小文字を区別しません。loopback（`127.0.0.1` / `localhost` / `[::1]`）はポート省略でも許可します。`/api/session/prompt` 以外の非 GET/HEAD リクエスト全てが対象です。
- Web 会話の実行中は、`launch`（同じプロジェクト）と `apply-all`（全体）を 409 `PROMPT_IN_PROGRESS` で拒否します。
- 監査ログ（`web-startup-audit.log`）には、拒否も含めて記録します。**本文は記録せず**、長さと SHA-256 先頭 12 桁、認証した主体のみです。
- resume に失敗した Web 会話の系譜は破棄し、次回は新規会話（または分岐）から始めます。破棄するのは「会話が始まらなかった（`system/init` が来ない）」ときだけで、
  中断・タイムアウト・予算超過・ツール失敗では、claude 側に会話が残っているため系譜を保持します。
- 認証前の拒否（Host / Origin / 認証失敗など）の監査は、同じ理由につき 1 分に 1 件へ間引きます（ログ肥大の防止）。認証後の拒否は常に記録します。
- JWT 検証: `alg` は RS256 固定、`kid` は文字列必須。未知の `kid` は鍵を 1 度だけ再取得します（鍵のローテーション対応。強制再取得は 60 秒に 1 回まで）。
  JWKS を取得できないときは fail-closed（`JWKS_UNAVAILABLE`）です。

## 既知の限界（別 PR で扱う）

- `launch` / `stop` などの変更系 API は、Origin を**必須にはしていません**（CLI からの直接呼び出しのため）。ブラウザは別サイトからの POST に必ず Origin を付けるため CSRF は防げますが、
  Origin を持たない非ブラウザのクライアントは、認証（Basic / Cloudflare Access）さえ通れば呼び出せます。
- 運用者が `STARTUP_WEB_PROMPT_ENV_PASS` で渡した変数は、秘密であっても子へ渡ります（意図した上書きです）。
- Basic 認証のモードでは、監査の `user` が常に `claudeos` になります（個人は特定できません）。JWT モードではメールアドレスが残ります。

## 残余リスク（正直な評価）

- **プロンプトによる任意コード実行は、機能の本質として許容されています。** `--permission-prompts none` のため、許可されていない操作は拒否されますが、
  `auto` モードでは分類器の判断でホスト上のコマンドが実行されます。権限モードは既定の `acceptEdits` を推奨します。
- 環境変数の除去は、ファイルの直接読み取り（`~/.env-claudeos`・`~/.git-credentials` など）を防ぎません。子の `claude` はユーザーの権限で動きます。
- 対象プロジェクトの `.claude/settings.json`・hooks・MCP・`CLAUDE.md` は子の `claude` に読み込まれます。侵害されたリポジトリの内容が Web の権限で動き得ます。
- Cloudflare Access のアカウントが乗っ取られると、停止中の全プロジェクトで同等のことができます。MFA の強制と、Access の許可対象の最小化を前提にしてください。
  1 回あたりの上限と、1 日あたりの回数・累計予算の上限があります（既定 50 回・10 USD）。
- 利用者のブラウザには、`claude` の応答本文（`result` / `assistant`）がそのまま届きます。

## 無効化・切り戻し

- `STARTUP_WEB_PROMPT_ENABLE` を外して Web サービスを再起動すれば、機能は止まります（既存の API・画面は影響を受けません）。
- 画面のコードを戻す場合は、このブランチのコミットを revert します（`~/.claudeos/web-prompt/` の系譜ファイルは残っても無害です）。
