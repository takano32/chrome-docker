# 共有 CDP ブラウザ（Google Chrome）と chrome-devtools-mcp を1つのイメージに入れる。
# Chrome は Google の apt リポジトリから入れる。arm64 の google-chrome-stable も配られている
# （2026-10-25 に dists/stable/Release の Architectures: amd64 arm64 を確認）。
FROM node:22-bookworm-slim

# ビルド中だけ対話を切る（ENV だと実行時の環境にも残るので ARG にする）
ARG DEBIAN_FRONTEND=noninteractive

# Google の Linux パッケージ署名鍵（ASCII armored）。signed-by でこのリポジトリにだけ使わせる。
# bookworm の apt（2.6）は armored の鍵をそのまま読めるので gnupg は要らない。
ADD --chmod=644 https://dl.google.com/linux/linux_signing_key.pub /etc/apt/keyrings/google-chrome.asc

# Chrome の版。空なら apt の最新（Google のリポジトリにある stable）。固定したいときは
# compose / .env の CHROME_VERSION に `156.0.8078.47-1` の形で渡す。
# ⚠️ Google のリポジトリも最新版しか置かないので、固定した版が次の更新で消えるとビルドが
# 止まる（止まるのは意図＝版を上げる判断を人がする）。
# 入っている版は `docker run --rm --entrypoint /opt/google/chrome/chrome chrome-docker:local --version`。
ARG CHROME_VERSION=

# 1. ca-certificates: Google のリポジトリは https なので先に Debian のミラー（http）から入れる
# 2. /etc/default/google-chrome: deb の postinst が自分のリポジトリ設定（google-chrome.sources）
#    を足すのを止める（repo_add_once="false"）。設定はこのファイルの sources.list.d だけにする
# 3. google-chrome-stable: ブラウザ本体（/opt/google/chrome/chrome）
#    fonts-noto-cjk: 日本語ページのスクリーンショットが豆腐にならないように
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/google-chrome.asc] https://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google.list \
 && echo 'repo_add_once="false"' > /etc/default/google-chrome \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      "google-chrome-stable${CHROME_VERSION:+=$CHROME_VERSION}" \
      fonts-noto-cjk \
 && rm -rf /var/lib/apt/lists/*

# 版は compose / .env から渡す（既定は 2026-10-25 時点の最新 1.12.0）
ARG MCP_VERSION=1.12.0
RUN npm install -g "chrome-devtools-mcp@${MCP_VERSION}" \
 && npm cache clean --force

# root では動かさない。--no-sandbox（下の compose）と root が重なると、レンダラが破られた
# ときコンテナの root まで届く。node イメージ付属の非特権ユーザー（uid 1000）で動かす。
# Chrome も MCP もこのユーザーで動くことは実測済み（--user-data-dir は /tmp の下）。
USER node

# 既定の入口は MCP サーバ（stdio）。ブラウザとして使うときは compose 側で
# entrypoint を /opt/google/chrome/chrome に差し替える。
ENTRYPOINT ["chrome-devtools-mcp"]
