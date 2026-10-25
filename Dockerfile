# 共有 CDP ブラウザ（chromium）と chrome-devtools-mcp を1つのイメージに入れる。
# この箱は arm64 なので Google Chrome の deb は使えない。Debian の chromium を使う。
FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# chromium: CDP を喋るブラウザ本体
# fonts-noto-cjk: 日本語ページのスクリーンショットが豆腐にならないように
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      chromium \
      ca-certificates \
      fontconfig \
      fonts-noto-cjk \
 && rm -rf /var/lib/apt/lists/*

# 版は compose / .env から渡す（既定は 2026-10-25 時点の最新 1.12.0）
ARG MCP_VERSION=1.12.0
RUN npm install -g "chrome-devtools-mcp@${MCP_VERSION}"

# 既定の入口は MCP サーバ（stdio）。ブラウザとして使うときは compose 側で
# entrypoint を /usr/bin/chromium に差し替える。
ENTRYPOINT ["chrome-devtools-mcp"]
