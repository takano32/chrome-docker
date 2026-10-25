# chrome-docker

[chrome-devtools-mcp](https://github.com/ChromeDevTools/chrome-devtools-mcp) と、それが喋る相手の
headless chromium を1つのイメージに入れて、ブラウザだけを compose で常駐させる。

狙いは「ブラウザを1本だけ立てて、複数のボットが CDP で相乗りする」。各自が自分の chrome を
起動するとプロセスもメモリも二重になり、逆に他人のブラウザに相乗りすると「相手が先に起動して
いる」依存ができる。第三の常駐にして、どちらのボットの再起動にも振り回されないようにする。

本家リポジトリは clone も改変もしない。`npm install -g chrome-devtools-mcp@<版>` で入れるだけ。
版は `.env` の `MCP_VERSION`（2026-10-25 時点の最新 1.12.0）。

## 前提

- docker（この箱は 29.9.2）と compose plugin。
- イメージは arm64 で作る。Google Chrome の deb は arm64 版が無いので、Debian の chromium を使う。

## 使い方

```bash
cd ~/opt/chrome-docker
docker compose up -d --build     # 初回はビルド（chromium + MCP）
docker compose ps
curl -s http://127.0.0.1:9223/json/version   # CDP が返れば成功
```

止める・消す:

```bash
docker compose down            # ブラウザを止める（イメージは残る）
docker compose down --rmi local  # イメージも消す
```

### Hermes の MCP として使う

MCP サーバは常駐させない。stdio なので、Hermes がその都度 `docker run -i` で起動して
常駐ブラウザに相乗りさせる。

```bash
hermes mcp add chrome-devtools \
  --command docker \
  --args run -i --rm --network host chrome-docker:local \
         --browserUrl http://127.0.0.1:9223 \
         --headless --isolated --no-usage-statistics
```

`--network host` はホストの 127.0.0.1:9223 に繋ぐため。ブラウザ側は 127.0.0.1 にしか
待ち受けていないので、外からは触れない。

compose の中で完結させたいときは `mcp` サービス（`profiles: ["mcp"]`）を使う:

```bash
docker compose run --rm -T mcp
```

### nilkani06 側から使う

同じ CDP に相乗りするなら、向こうの chrome-devtools-mcp の起動引数を
`--browserUrl http://127.0.0.1:9223` に変える（`--headless --isolated` は外す）。
ポートは `.env` の `CDP_PORT` で決まる。移行が済んだら 9222 に寄せてもよい。

## 構成

- `Dockerfile` — `node:22-bookworm-slim` + Debian chromium + `chrome-devtools-mcp`（arm64）
- `compose.yml` — `chrome`（常駐、CDP を 127.0.0.1:9223 に公開）と `mcp`（都度起動、stdio）
- `.env` — `MCP_VERSION` と `CDP_PORT`

## 注意（実測で踏んだこと）

- **ホストのネットワークを使っている**（`network_mode: host`）。Debian の chromium は
  `--remote-debugging-address=0.0.0.0` を渡しても `127.0.0.1` にしか束縛せず、ポート公開
  （docker-proxy）越しだと接続がリセットされる。host network にしたらホストの
  `127.0.0.1:9223` からそのまま繋がった。ポート番号は内外で揃える（Chrome は Host ヘッダの
  ポートが `--remote-debugging-port` と違うと接続を切る）。
- コンテナ内に user namespace が無いので chromium は `--no-sandbox` で動かす。外向けの
  ポートは開けていない（127.0.0.1 のみ）ので、その前提での割り切り。
- 実測（2026-10-25）: イメージ 1.54GB、コンテナのメモリ 165MB、`/json/version` は
  `Chrome/156.0.8078.47` を返す。MCP を `docker run -i` で繋ぐと 32 ツールが見えた
  （`click` / `evaluate_script` / `lighthouse_audit` など）。
- `--user-data-dir` は `/tmp/chrome-profile`。コンテナを作り直すとログイン状態などは消える。
  残したいものが出てきたら named volume に移す。
- メモリは idle で PSS 270MB 前後（ホスト直実行の同じ構成で実測）。`renderer-process-limit=1`
  と `--disable-gpu` で抑えてある。
