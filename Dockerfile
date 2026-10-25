# 共有 CDP ブラウザ（chromium）と chrome-devtools-mcp を1つのイメージに入れる。
# この箱は arm64 なので Google Chrome の deb は使えない。Debian の chromium を使う。
FROM node:22-bookworm-slim

# ビルド中だけ対話を切る（ENV だと実行時の環境にも残るので ARG にする）
ARG DEBIAN_FRONTEND=noninteractive

# chromium の版。空なら apt の最新（bookworm-security の更新がそのまま入る）。
# 固定したいときは compose / .env の CHROMIUM_VERSION に `156.0.8078.47-1~deb12u1` の
# 形で渡す。⚠️ Debian の security アーカイブには最新版しか置かれないので、固定した版が
# 次の更新で消えるとビルドが止まる（止まるのは意図＝版を上げる判断を人がする）。
# 入っている版は `docker run --rm --entrypoint chromium chrome-docker:local --version`。
ARG CHROMIUM_VERSION=

# chromium: CDP を喋るブラウザ本体
# fonts-noto-cjk: 日本語ページのスクリーンショットが豆腐にならないように
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      "chromium${CHROMIUM_VERSION:+=$CHROMIUM_VERSION}" \
      ca-certificates \
      fontconfig \
      fonts-noto-cjk \
 && rm -rf /var/lib/apt/lists/*

# 版は compose / .env から渡す（既定は 2026-10-25 時点の最新 1.12.0）
ARG MCP_VERSION=1.12.0
RUN npm install -g "chrome-devtools-mcp@${MCP_VERSION}" \
 && npm cache clean --force

# root では動かさない。--no-sandbox（下の compose）と root が重なると、レンダラが破られた
# ときコンテナの root まで届く。node イメージ付属の非特権ユーザー（uid 1000）で動かす。
# chromium も MCP もこのユーザーで動くことは実測済み（--user-data-dir は /tmp の下）。
USER node

# 既定の入口は MCP サーバ（stdio）。ブラウザとして使うときは compose 側で
# entrypoint を /usr/bin/chromium に差し替える。
ENTRYPOINT ["chrome-devtools-mcp"]
