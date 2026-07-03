---
name: 🔐 JIT 単発承認チケット
about: 人間最終決断領域の操作を「1 回限り・期限付き」で承認依頼する（恒久的な権限拡大なし）
title: "jit: "
labels: ["jit-approval", "human-decision"]
assignees: []
---

## 🎯 実行したい操作（1 チケット 1 操作）

<!-- 例: PR #99 の main 宛 merge / secrets XXX の登録 / データ移行スクリプトの本番実行 -->

- **操作**:
- **対象**:
- **実行コマンド（そのまま実行できる形で）**:

```bash

```

## ⏱ 有効期限（TTL）

<!-- 承認後この期限を過ぎたら失効。再実行には新チケットが必要 -->

- 期限: YYYY-MM-DD HH:MM (JST)

## ⚠️ リスクと影響範囲

-

## 🔄 ロールバック手順

-

## ✅ 承認方法（人間が実施）

以下のいずれかで承認する。承認がない限り CTO は実行しない。

- [ ] このチケットに `approved` ラベルを付与する
- [ ] コメントで `approve` と明記する

## 📋 実行記録（CTO が実行後に記入）

- 実行日時:
- 実行結果:
- audit 記録: `.claude/claudeos/data/audit-log.jsonl` へ追記済み: yes / no
