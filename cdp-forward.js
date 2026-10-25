// コンテナの外向き IP の <port> で待ち、同じコンテナの 127.0.0.1:<port>（Chrome の CDP）へ素通しする。
// 依存なし（node の net だけ）。中身は一切見ないので、Host ヘッダも webSocketDebuggerUrl も
// Chrome がホスト側の接続先（127.0.0.1:<port>）をそのまま写す。
// 使い方: node cdp-forward.js <port>   （entrypoint.sh が CDP_PORT を渡す）
'use strict';
const net = require('node:net');
const os = require('node:os');

const port = Number(process.argv[2]);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  console.error(`[cdp-forward] bad port: ${process.argv[2]}`);
  process.exit(2);
}

// 外向き IP（eth0）。無ければ 0.0.0.0。127.0.0.1 では待たない（Chrome と同じ番号で競合する）。
const external = Object.values(os.networkInterfaces())
  .flat()
  .find((i) => i && i.family === 'IPv4' && !i.internal);
const address = external ? external.address : '0.0.0.0';

const server = net.createServer((client) => {
  const upstream = net.connect(port, '127.0.0.1');
  const close = () => {
    client.destroy();
    upstream.destroy();
  };
  client.on('error', close);
  upstream.on('error', close);
  client.on('close', close);
  upstream.on('close', close);
  client.pipe(upstream);
  upstream.pipe(client);
});

server.on('error', (err) => {
  console.error(`[cdp-forward] listen ${address}:${port} failed: ${err.message}`);
  process.exit(1);
});

server.listen(port, address, () => {
  console.error(`[cdp-forward] ${address}:${port} -> 127.0.0.1:${port}`);
});
