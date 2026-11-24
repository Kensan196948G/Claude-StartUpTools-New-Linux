# Ship Native セキュリティモデル

状態: 2026-11-24 実装・検証。脅威の前提は実機で確認した事実に基づく。

## 1. 前提（実機確認 2026-11-24）

| 事実 | 確認方法 | 帰結 |
| --- | --- | --- |
| AI エージェントは人間と同じ OS ユーザー `kensan` で動く | `id` | OS のファイル所有・権限では人間と AI を区別できない |
| そのユーザーはパスワード無し sudo（`(ALL) NOPASSWD: ALL`）を持つ | `sudo -n -l` | root 所有ファイルに置いても AI は書き換えられる |
| gh の active token は `repo` / `workflow` スコープ、リポジトリ権限は ADMIN | `gh auth status` / `gh repo view` | AI は任意の Commit Status を付けられ、ruleset も変更できる |
| リポジトリは PUBLIC | `gh repo view` | `/ship` は未コミット変更をコミットしない（公式仕様） |
| ruleset `central-auto-merge` は承認 0・必須チェック 2 つ・bypass actor なし | REST API | 現状は Required Checks 成功だけでマージされる |

**結論: Web 画面のボタン、OS 権限、ファイル配置では「人間が承認した」を証明できない。**
本実装は、人間だけが知る**パスフレーズの知識**を承認の証明の根拠にする。

## 2. Human Gate の構成

```
人間の端末 (/dev/tty)
  │ パスフレーズ (echo なし。引数・環境変数・パイプでは受け付けない)
  ▼
鍵束 ~/.config/claudeos-approver/key.json
  Ed25519 秘密鍵 ← scrypt(N=2^17,r=8,p=1) + AES-256-GCM で暗号化
  (任意) 人間専用 GitHub App の秘密鍵 ← 同じく暗号化
  │
  ▼ 署名
承認レコード {repo, pr, head_sha, base_sha, gate_hash, quality_evidence_hash, risk, approver,
             key_id, issued_at, expires_at(24h), nonce, policy_version, decision} + signature
  │
  ├─▶ Merge Executor が検証:
  │     信頼鍵 = base ブランチ (origin/main) の config/ship-policy.json humanGate.approverKeys
  │     署名 / head・base 一致 / 期限 / 取り消し / nonce 未使用 / gate 再判定と hash 一致
  │
  └─▶ GitHub: head SHA に Commit Status `claudeos/human-approval=success`
        (GitHub App があれば App として登録。ただし AI の token が admin 権限を持つ間は ruleset を書き換えられるため、偽装の完全な防止にはトークン分離が前提)
```

## 3. 脅威と対策

| 脅威 | 対策 | 検証 |
| --- | --- | --- |
| AI が承認を偽装・代理生成する | 署名にパスフレーズ保護の秘密鍵が必要。AI の Bash tool には TTY が無く入力経路が無い | `human-gate.test.js` 偽装 3 件 / `ship.bats` NO_TTY |
| AI が自前の鍵を作って署名 | 信頼鍵は base ブランチのポリシーの fingerprint のみ | KEY_NOT_TRUSTED テスト |
| PR 内でポリシーを緩める（鍵追加・人間承認無効化） | 判定・承認・マージは `git show origin/main:config/ship-policy.json` を読む。`requiredForAllRisks=false` は読み込み拒否 | loadTrustedPolicy テスト |
| 承認後のコード差し替え | 承認は head SHA に固定。GitHub の Commit Status も SHA 単位なので新 SHA に承認は無い | STALE_HEAD テスト / 監視の auto-merge 解除テスト |
| base 側の変更 | base SHA も署名対象。ruleset strict により update-branch が必要 = head も変わる | STALE_BASE テスト |
| 承認の再利用・リプレイ | nonce を排他作成で消費（2 回目は失敗）。DB でも UNIQUE 制約 | NONCE_CONSUMED テスト |
| 承認後に品質判定が変わる | gate_hash を署名対象にし、マージ直前に再判定と照合 | GATE_CHANGED テスト |
| 品質証跡の改ざん | evidence_hash + HMAC。改ざん証跡は判定入力から除外 | HMAC_MISMATCH テスト |
| 古い SHA の合格結果の流用 | 証跡は SHA ごとのディレクトリ。中身の head_sha も照合 | SUBJECT_MISMATCH テスト |
| テストコードによる認証情報窃取・外部送信 | bwrap: `--unshare-net`、$HOME を tmpfs で隠す（gh / claude / 鍵束 / HMAC 鍵が見えない）、`--clearenv` | 隔離プローブテスト（漏洩 0） |
| テストがリポジトリの HEAD を動かす | 実行前後で HEAD を照合し、変わっていれば UNKNOWN | HEAD_MOVED テスト |
| 未承認マージ（auto-merge 登録が即マージになる） | ruleset が 2 context を必須にしていることを API で確認してからのみ登録 | RULESET_DOES_NOT_REQUIRE テスト |
| 承認経路外のマージ | 監視が検出し、run を STOPPED（成功扱いにしない）・監査記録 | MERGED_OUTSIDE_HUMAN_GATE テスト |
| Web コンソール経由の権限昇格 | 承認エンドポイントを作らない。取り消し（安全側）のみ Access JWT + メール形式必須 | `ship-api.test.js` |
| PR 本文・コメント経由の不正指示 | ClaudeOS の判定は GitHub API の構造化データ（state / SHA / checks）だけを使い、自然言語を命令として解釈しない | 設計 |
| 秘密情報のログ混入 | 全レコードを `redact()` 経由で保存。シークレット検査は位置とルール ID のみ記録 | redact テスト / trivy ログテスト |
| 無限ループ・過剰実行 | 日次上限、最大再試行、指数バックオフ、サーキットブレーカー | DAILY_CAP / CIRCUIT_OPEN テスト |
| 監査ログの改ざん | prev_hash 連鎖。改ざん・削除を検出 | HASH_MISMATCH / CHAIN_BROKEN テスト |

## 4. 残存リスク（隠さない）

1. **root 権限を持つ能動的に悪意あるエージェント**は、人間の承認プロセスのメモリ読み取りや端末入力の盗聴が理論上可能。
   完全な対策は AI を **sudo 無しの別 OS ユーザー**で動かすこと（承認事項 #7）。
2. **Commit Status の偽装**: AI のトークンから admin 権限を外し（#7・トークン分離）、そのうえで GitHub App 化と ruleset の integration_id 限定（#4）を行うまでは、
   admin token を持つ AI が `claudeos/human-approval=success` を付け得る。ClaudeOS の Merge Executor は署名を検証するので
   ClaudeOS 経由では起きないが、AI が直接 `gh pr merge` すれば GitHub は通してしまう。
   グローバルフック `kensan-auto-merge-guard.py` は `--match-head-commit` 必須化までで、承認の有無は見ない。
3. **HMAC 鍵と証跡は同一 OS ユーザーが読める**ため、証跡改ざんの「検出」はできるが「防止」はできない（OS ユーザー分離で解消）。
4. **ruleset 変更権限**（実測 2026-11-24: AI の gh トークンは所有者本人のもので admin・`repo` スコープ）: ADMIN token を持つ AI は ruleset を緩められる。**このため GitHub App（#4）だけでは意図的な偽装を防げず、#7・トークン分離とセットで検討する。**CLAUDE.md で禁止しているが技術的強制は無い。
   GitHub の ruleset 変更は監査ログに残るため、定期 readback を推奨。
5. `/ship` の watch は人間の gh / git 資格情報で動く（公式警告）。auto-merge 登録済み PR では watch の push がマージに至り得るため、
   Merge Executor は承認後・登録直前にのみ auto-merge を登録し、head 変化時は解除する。

## 5. Claude Code 設定との関係（実機確認）

| 設定 | 影響 | 対応 |
| --- | --- | --- |
| 本リポジトリ `.claude/settings.json` の `PreToolUse[matcher=Bash]`（pre-commit-gate） | 公式仕様により **`/ship` の watch が始まらない**（review は可能） | capability が `settings.project.hooks=fail` と報告。変更は承認事項 #8（フック削除は品質ゲート緩和になるため） |
| ユーザー設定の `kensan-auto-merge-guard.py` | watch 中に Claude Code 自身が実行する gh/git には PreToolUse は効かない | マージ防止は ruleset に依存すると明記 |
| ユーザー設定 `deny: git push --force*` | `/ship` 自身の push・watch を妨げない（`git push *` の deny ではない） | 問題なし |
| gh 2.45.0 → 2.105.0 | 2026-11-24 に更新済み（承認 #9） | `apt-mark hold gh` で apt 版 2.45 への戻りを防止 |
