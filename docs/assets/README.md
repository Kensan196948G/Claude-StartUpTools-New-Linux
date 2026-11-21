# 🖼️ docs/assets — README 用の図・スクリーンショット・デモ動画

このディレクトリは README（入口ドキュメント）で使う**表示資産**の置き場です。
数字や主張の根拠となる文書ではなく、画面と動きを伝えるための素材です。

## 一覧

| ファイル | 種類 | 内容 |
|---|---|---|
| `demo/claudeos-demo.mp4` | 動画（10 秒・音声なし・1280x800 / H.264） | 統合コンソールの操作（起動 → 計画 → 診断 → 品質 → 監査ログ） |
| `demo/claudeos-demo.gif` | アニメーション（900px・10fps・ループ） | 上の動画のループ版（GitHub で自動再生される） |
| `demo/architecture.svg` | アニメーション SVG | 全体アーキテクチャ（人 → 入口 → 起動 → Supervisor → Claude Code → GitHub / CI） |
| `demo/modes.svg` | アニメーション SVG | 3 つの起動モード（L1 / T1 / S1）の違い |
| `demo/supervisor-loop.svg` | アニメーション SVG | Supervisor の判定ループとガードレール |
| `screens/*.png` | 静止画 | Web コンソールの画面（起動・セッション監視・Supervisor 全適用・診断・品質・監査） |

## 撮影方法（再現できるように）

デモ動画とスクリーンショットは、**隔離したデモ環境**で実際の統合コンソールを操作して撮影しています。
本番のプロジェクト名・セッション・ログは写していません。

1. デモ用の Git リポジトリを 3 つ作る（`demo-web` / `demo-api` / `demo-batch`）。
2. `config/config.json` の `projects` をそのフォルダへ向け、`projectGroups` / `localExcludes` を空にする。
3. 環境変数で参照先を隔離して、統合コンソールを起動する。

   ```bash
   AI_STARTUP_CONFIG_PATH=/tmp/ccsu-demo/config.json \
   CLAUDEOS_HOME=/tmp/ccsu-demo/home \
   node scripts/web/startup-server.js --port 3840 --host 127.0.0.1 --allow-no-auth
   ```

4. Playwright（Chromium）の `recordVideo` で操作を録画する。カーソル・キャプションは撮影用にページへ注入した注釈で、UI 自体は加工していない。
5. `ffmpeg` で MP4（H.264 / yuv420p）と GIF（パレット生成 → `paletteuse`）に変換する。

```bash
# MP4（10 秒へトリム・等速化）
ffmpeg -ss 2.60 -to 16.55 -i raw.webm \
  -vf "setpts=(PTS-STARTPTS)/1.395,fps=25,scale=1280:800:flags=lanczos" \
  -c:v libx264 -preset slow -crf 22 -pix_fmt yuv420p -movflags +faststart -an claudeos-demo.mp4

# GIF（パレット生成 → 適用）
ffmpeg -i claudeos-demo.mp4 \
  -vf "fps=10,scale=900:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=80:stats_mode=full[p];[s1][p]paletteuse=dither=none:diff_mode=rectangle" \
  -loop 0 claudeos-demo.gif
```

## 方針

- 画面は**実際の UI**を撮る。成功していない状態を成功に見せる加工はしない。
- 「未接続」「未確定」「読み取り専用」など、コンソールが表示している注意書きは消さない。
- 図（SVG）は説明のための図であり、実装の証拠ではない。数値の根拠は `README.md` の「検証（実測値）」と各ドキュメントを参照する。
