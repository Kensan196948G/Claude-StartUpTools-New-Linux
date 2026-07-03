# JIT 単発承認プロトコル — 恒久昇格なしの 1 回限り承認

## 概要

「人間最終決断」領域の操作（main 宛 merge、Secrets、課金、破壊的削除、本番公開等）を、
**権限を恒久的に拡大せずに 1 回限り・期限付きで承認**する手順。
Anthropic の agent identity モデルにおける JIT credentials の考え方を、
Issue ベースの運用へ翻案したもの。

対話セッション中は従来どおり「マージしますか？ [y/N]」の直接確認でよい。
本プロトコルは **cron / headless 無人セッションで人間決断が必要になった場合**の正本手順。

## 原則

- ✅ 1 チケット 1 操作（複数操作の抱き合わせ禁止）
- ✅ TTL 必須（期限を過ぎた承認は失効。再実行には新チケット）
- ✅ 実行はチケットに書かれたコマンドのとおり 1 回のみ（拡大解釈禁止）
- ✅ 実行後は audit 記録（`.claude/claudeos/data/audit-log.jsonl`）へ追記
- 🚫 承認をもって恒久的な権限・設定変更とみなさない

## フロー

```
CTO が禁止境界の操作に到達
  → jit-approval テンプレートで Issue 起票（操作・対象・コマンド・TTL・リスク・ロールバック）
  → Session Report の「人間決裁待ちキュー」へ 1 行追加
  → 人間が approved ラベル付与 or コメント "approve"
  → CTO（次セッション）が TTL 内かを確認して 1 回だけ実行
  → 実行記録をチケットへ記入し close。audit 追記
```

## CTO 側の判定手順（headless）

```bash
# 承認済み・未失効の JIT チケットを列挙
gh issue list --label jit-approval --label approved --state open --json number,title,body

# 各チケットについて:
#  1. body の TTL が現在時刻より未来であること（過ぎていれば "expired" コメントを付けて close）
#  2. 記載コマンドをそのまま 1 回実行
#  3. 実行記録セクションを更新し close
```

## 関連文書

- 恒常的な自動 merge 条件: `auto-merge-protocol.md`（JIT は auto-merge 条件を満たさない例外操作のための経路）
- Trust Level 運用: `trust-ledger.md`（JIT 承認の履歴は昇格判断の材料にしない — 単発例外であり実績ではない）
