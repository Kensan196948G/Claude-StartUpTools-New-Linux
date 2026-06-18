# 12. Claude Design 連携

Claude Design と Claude Code を往復させ、リポジトリの実デザインシステムに沿った UI 実装へつなげる手順です。

## 前提

- Claude Code は最新化済みであること。
  - 確認: `claude --version`
  - 更新: Claude Code 内で `/update`
- Claude Design beta を利用できるプランであること。
  - Pro / Max / Team / Enterprise が対象。
  - Enterprise は管理者が Claude Design を有効化している必要がある。
- Claude Code が Claude サブスクリプションで認証済みであること。
  - 初回: `claude auth login`
  - `/design` または `/design-sync` が見えない場合は `/update` 後に新規セッションを開始する。

## 初回セットアップ

```bash
claude --version
claude auth login
claude
```

Claude Code の新規セッション内で次を実行します。

```text
/update
```

更新後、Claude Code を一度終了して新規セッションを開始します。

## デザインシステム同期

UI 実装または UI 改修に入る前に、Claude Code 内で次を実行します。

```text
/design-sync
```

期待する効果:

- local codebase の component library / design tokens / CSS / Tailwind 設定を Claude Design へ同期する。
- Claude Design 側で、生成物が既存デザインシステムに準拠しているかを自動確認する。
- 既存コンポーネント、色、タイポグラフィ、spacing、layout pattern を使った prototype 生成を優先する。

## 事前チェック

同期前に ClaudeCode 内で次を実行します。

```text
/design-sync-check
```

確認対象:

- design tokens: 色、typography、spacing、radius、shadow
- component library: button、input、modal、navigation、card、table など
- Tailwind / CSS variables / theme 設定
- Storybook または component catalog
- screenshot / visual regression の有無
- accessibility baseline

不足がある場合は、Claude Design に渡す前に不足リストを作り、必要最小限の整備を行います。

## Claude Design での作業

Claude Design では、次の順で進めます。

1. `/design-sync` 済みの design system を選ぶ。
2. 画面の目的、利用者、主要状態、データ密度、制約を指定して prototype を作る。
3. canvas 上で直接編集する。
4. inline comment で細部を修正する。
5. layout / spacing / color / text を確認する。
6. 完成したら handoff bundle を Claude Code に渡す。

## Claude Code への実装引き渡し

Claude Design の handoff bundle を Claude Code に渡したら、Claude Code 側では次を守ります。

- 既存コンポーネントを優先して実装する。
- 新しい UI 部品は、既存 design token と命名規則に合わせる。
- mock screenshot だけを根拠にせず、handoff の component / token / interaction notes を読む。
- 実装後に lint / test / build に加えて、visual regression または screenshot 確認を行う。
- accessibility を最低限確認する。

## 運用上の注意

- `/design-login` は公式手順として確認できないため、認証は `claude auth login` と Claude Code のログイン誘導を使う。
- Claude Design は beta のため、canvas コメントや複数人編集は安定しない場合がある。
- 大規模 repo では同期対象を component library / design token / representative screens に絞る。
- design system import の品質は元 repo の整理状態に依存する。不要な実験 UI や古い theme が混ざる場合は同期前に除外方針を決める。
