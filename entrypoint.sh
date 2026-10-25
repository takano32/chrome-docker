#!/bin/sh
# chrome-docker の入口。引数はそのまま chrome-devtools-mcp に渡す（既定は Dockerfile の CMD）。
#
# CDP_PORT が設定されていれば、その接続の Chrome の CDP をホストから使えるようにする:
#   1. MCP に --chromeArg=--remote-debugging-port=$CDP_PORT を足す
#      （Chrome はコンテナの 127.0.0.1:$CDP_PORT にしか束縛しない）
#   2. cdp-forward.js が、コンテナの外向き IP の同じ番号で待ち、127.0.0.1:$CDP_PORT へ転送する
#      （docker-proxy はコンテナの IP に繋ぎに来るので、この転送役が要る）
#   ホスト側は `-p 127.0.0.1:$CDP_PORT:$CDP_PORT` で受ける（README「CDP をホストから使う」）。
# CDP_PORT が無ければ何も開かない（既定）。
set -eu

if [ -n "${CDP_PORT:-}" ]; then
  # stdout は MCP の stdio なので、転送役の出力は stderr にだけ流す
  node /usr/local/bin/cdp-forward.js "$CDP_PORT" </dev/null >&2 &
  set -- "$@" "--chromeArg=--remote-debugging-port=$CDP_PORT"
fi

exec chrome-devtools-mcp "$@"
