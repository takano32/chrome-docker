# chrome-devtools-mcp と、それが起こす headless Google Chrome を1つのイメージに入れる。
# 既定の使い方は「MCP の接続1本ごとにコンテナを1つ起こし、その中で MCP が自分の Chrome を起こす」。
# 常駐ブラウザに相乗りする形は compose の profile "shared"（任意）。
# Chrome は Google の apt リポジトリから入れる。arm64 の google-chrome-stable も配られている
# （2026-10-25 に dists/stable/Release の Architectures: amd64 arm64 を確認）。
FROM node:24-bookworm-slim

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

# chrome-devtools-mcp の版。空なら npm の latest。固定したいときは compose / .env の
# MCP_VERSION に `1.12.0` の形で渡す（CHROME_VERSION と同じ流儀）。
# ⚠️ npm の層もビルドキャッシュに残るので、最新を取り込むには `docker compose build --no-cache`。
ARG MCP_VERSION=
RUN npm install -g "chrome-devtools-mcp@${MCP_VERSION:-latest}" \
 && npm cache clean --force

# root では動かさない。--no-sandbox と root が重なると、レンダラが破られたときコンテナの
# root まで届く。node イメージ付属の非特権ユーザー（uid 1000）で動かす。
# Chrome も MCP もこのユーザーで動くことは実測済み（user-data-dir は /tmp の下）。
USER node

# 入口は MCP サーバ（stdio）。引数を渡さなければ CMD の既定＝MCP がコンテナの中で自分の
# Chrome を起こす（puppeteer が /opt/google/chrome/chrome を見つけるので --executablePath は
# 要らない。pipe で繋ぐのでポートは開かない）。
#   --headless                       画面は無い
#   --isolated                       使い捨ての user-data-dir（コンテナごと消える）
#   --chromeArg=--no-sandbox         Docker 既定の seccomp では sandbox が使えない（README「注意」）
#   --chromeArg=--js-flags=...       1ページが V8 ヒープを食い潰しても 512MB で止める
#   --no-usage-statistics / --no-performance-crux  Google へ送らない
# 常駐ブラウザに相乗りするときは、引数を全部渡して差し替える（compose の mcp-shared を参照）。
ENTRYPOINT ["chrome-devtools-mcp"]
CMD ["--headless", "--isolated", "--chromeArg=--no-sandbox", "--chromeArg=--js-flags=--max-old-space-size=512", "--no-usage-statistics", "--no-performance-crux"]
