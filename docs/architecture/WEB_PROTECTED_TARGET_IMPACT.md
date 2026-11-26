# 影響分析とロールバック: 保護対象判定の部分一致を意図した fail-closed と明記（PR #243、R3）

状態: 2026-11-26。PR #243 の R3 要件（変更影響分析・ロールバック手順）を満たすための文書。

## 1. 変更内容

- `scripts/web/startup-server.js`: `isProtectedOpsTarget` の JSDoc コメントに、部分一致（大文字小文字を区別しない）を維持する理由を追記する。**実行されるコードは変えない。**
- `scripts/web/startup-server.test.js`: 境界の 3 件（`cftunnel`・`wind-tunnel-sim`・`CloudflaredQuick`）が保護対象になることを固定するテストを追加する。

## 2. 影響分析

| 観点 | 影響 | 根拠 |
| --- | --- | --- |
| 実行時の挙動 | なし。判定式 `/web-startup\|cloudflared\|tunnel/i` は変更しない | diff はコメントとテストのみ |
| 保護の強さ | 変わらない（弱めていない） | |
| 誤拒否 | tunnel を含む正当な名前（例: `wind-tunnel-sim`）は引き続き拒否される。判断として許容し、PR 本文に根拠を残した | 狭めると `cftunnel` 等が保護から外れ、再起動で唯一の経路を切る恐れがある |
| テスト | `startup-server.test.js` 117 件成功 | |
| セキュリティ・データ・migration | なし | |

## 3. ロールバック手順

`git revert <マージコミット>`。コメントとテストのみの変更のため、戻しても実行時の挙動は変わらない。
