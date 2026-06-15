# 08-operations — 運用ルール (v9.0)

## 🎯 目的

ClaudeOS v9.0 を `/goal` 駆動・動的判断モードで安全に運用する。

---

## 🔁 基本実行フロー（v9.0 動的判断）

```text
/goal 設定 → CTO 優先順位評価 → 最適行動選択 → 実行 → /goal 達成判定
```

フォールバック: `Monitor → Development → Verify → Improvement`

---

## 👔 CTO 優先順位（v9.0）

| 優先度 | 状態 | 行動 |
|---|---|---|
| 1 | Security Critical | 即時対応 |
| 2 | CI 失敗中 | 修復 |
| 3 | Blocker Issue | 解除 |
| 4 | /goal 直結 Issue | 実装 |
| 5 | 検証不足 | 品質強化 |
| 6 | 改善 | 余裕時のみ |

---

## 🟢 Monitor

確認対象:

- state.json
- GitHub Issues
- GitHub Pull Requests
- GitHub Projects
- GitHub Actions
- backlog.md
- TODO.md
- docs/roadmap.md
- **Claude Code changelog**（`https://code.claude.com/docs/en/changelog`）

### 📜 changelog 定点観測（v9.0+ 運用化）

Monitor フェーズで Claude Code 本体の changelog 差分を確認し、運用ツールへ影響する
新機能・破壊的変更を取りこぼさない。**確認のみ**を行い、対応は Issue 化して次フェーズへ回す。

| 手順 | 内容 |
|---|---|
| 1 | `state.monitor.changelog_checked_version`（前回確認時の最新版）を読む |
| 2 | changelog の最新版と照合し、未確認バージョンの差分を抽出 |
| 3 | 運用影響のある項目を分類（後述）し、必要なら Issue 化 |
| 4 | `state.monitor.changelog_checked_version` を最新版へ更新 |

**運用影響の分類（Issue 化判断の指針）:**

| カテゴリ | 例 | 対応 |
|---|---|---|
| 🔧 設定キー追加/改称 | `teammateMode` / `worktree.baseRef` | settings.json・config テンプレへ反映 Issue |
| 🌀 オーケストレーション | `workflow`→`ultracode` 改称・`/effort xhigh` | 本ファイル / `04-agent-teams.md` 更新 Issue |
| ⌨️ tmux / 端末 | クリップボード・スクロール修正 | `libexec/setup-terminal.sh` 反映 Issue |
| 🤖 Agent / SubAgent | nesting 段数・teammate 仕様変更 | テンプレ agents 定義の見直し Issue |
| 🚨 破壊的変更 | 既定挙動の変更・廃止 | 即時 Issue 化（優先度 P1〜P2） |

> 💡 changelog は頻繁に更新されるため**毎 Monitor で全文精読は不要**。
> 前回確認版からの差分のみを見る（手順 1–2）。差分ゼロならスキップしてよい。

出力:

```text
Monitor Report:
- current_phase:
- open_issues:
- active_prs:
- ci_status:
- blockers:
- changelog_diff:    # 未確認版の有無 / 運用影響項目 / 起票した Issue
- next_target:
```

---

## 🔨 Development

実施内容:

- Issue選定
- ブランチ作成
- 最小単位実装
- 必要テスト追加
- 変更ログ作成

禁止:

- Release期の新機能開発
- 仕様外の大規模改修
- テストなし修正

---

## ✅ Verify

確認対象:

- lint
- unit test
- integration test
- build
- security check
- PR review
- Codex review

判定:

```text
pass → Improvement or Done
fail → CIManager / Codex Debug
```

---

## 🧹 Improvement

実施内容:

- 小規模リファクタリング
- テスト補強
- ドキュメント更新
- state.json学習更新
- Project同期

---

## 📋 GitHub Projects ステータス

```text
Backlog → Todo → In Progress → Review → Verify → Done
```

| トリガー | 状態 |
|---|---|
| Issue生成 | Backlog |
| 開発開始 | In Progress |
| PR作成 | Review |
| CI実行 | Verify |
| 完了 | Done |

---

## 🚨 Safety Guard（v9.0 Stop Conditions）

```
同一エラー同一原因 2 回連続 → Issue 化して次タスクへ
修復試行 3 回到達           → Blocked
コンテキスト圧迫警告        → 即終了処理
```

- 残 60 分 → 最終ループ
- 残 15 分 → Verify のみ
- 残 5 分 → 終了処理
- Security 最優先
