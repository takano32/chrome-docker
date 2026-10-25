# chrome-docker

[chrome-devtools-mcp](https://github.com/ChromeDevTools/chrome-devtools-mcp) と、それが喋る相手の
headless chromium を1つのイメージに入れて、ブラウザだけを compose で常駐させる。

狙いは「ブラウザを1本だけ立てて、複数のボットが CDP で相乗りする」。各自が自分の chrome を
起動するとプロセスもメモリも二重になり、逆に他人のブラウザに相乗りすると「相手が先に起動して
いる」依存ができる。第三の常駐にして、どちらのボットの再起動にも振り回されないようにする。

本家リポジトリは clone も改変もしない。`npm install -g chrome-devtools-mcp@<版>` で入れるだけ。
版は `.env` の `MCP_VERSION`（2026-10-25 時点の最新 1.12.0）。

## 前提

- docker（この箱は 29.9.2）と compose plugin（v5.6.1 で確認）。
- イメージは arm64 で作る。Google Chrome の deb は arm64 版が無いので、Debian の chromium を使う。

## 使い方

```bash
cd ~/opt/chrome-docker
docker compose up -d --build     # 初回はビルド（chromium + MCP）
docker compose ps
curl -s http://127.0.0.1:9223/json/version   # CDP が返れば成功
docker run --rm --entrypoint chromium chrome-docker:local --version   # 入っている chromium の版
```

止める・消す:

```bash
docker compose down            # ブラウザを止める（イメージは残る）
docker compose down --rmi local  # イメージも消す
```

chromium のセキュリティ更新を取り込む（apt の層はビルドキャッシュに残るので `--build` だけでは
更新されない）:

```bash
docker compose build --no-cache && docker compose up -d
```

### Hermes の MCP として使う

MCP サーバは常駐させない。stdio なので、Hermes がその都度 `docker run -i` で起動して
常駐ブラウザに相乗りさせる。

```bash
hermes mcp add chrome-devtools \
  --command docker \
  --args run -i --rm --network host chrome-docker:local \
         --browserUrl http://127.0.0.1:9223 \
         --no-usage-statistics --no-performance-crux
```

`--network host` はホストの 127.0.0.1:9223 に繋ぐため。ブラウザ側は 127.0.0.1 にしか
待ち受けていないので、外からは触れない。

**`--headless` と `--isolated` は付けない。**どちらも「MCP が自分で Chrome を起こすとき」の
引数で、`--browserUrl` で繋ぐ形では読まれない（1.12.0 の `BrowserManager.js` の `#connect` は
`browserUrl` / `wsEndpoint` / `wsHeaders` しか見ない。`--chromeArg` も同じ）。付けても隔離には
ならないことを実測した（`--isolated` 付きで繋いだ MCP から、別の MCP が置いたクッキーが見えた）。
隔離は下の「相乗りの作法」の `isolatedContext` で取る。

compose の中で完結させたいときは `mcp` サービス（`profiles: ["mcp"]`）を使う。`chrome` が host
network に居るので `mcp` も host network に載せ、`127.0.0.1` で繋ぐようにしてある:

```bash
docker compose run --rm -T mcp
```

MCP がファイルを書くツール（`take_screenshot` の `filePath`、`performance_start_trace` の
`filePath` など）は、クライアントが roots を渡さないと OS の一時ディレクトリにしか書けず、
それはコンテナの中なので `--rm` で消える。残したければ `-v <ホストの dir>:/out` を足して
`--workspace /out` を渡し、`/out` の下のパスを指定する（返り値に画像を含めるツールはそのまま使える）。

### nilkani06 側から使う

同じ CDP に相乗りするなら、向こうの chrome-devtools-mcp の起動引数のうち
`--headless --isolated --chromeArg=--remote-debugging-port=9222` を外して
`--browserUrl http://127.0.0.1:9223` に替える（`--no-usage-statistics --no-performance-crux` はそのまま）。
ポートは `.env` の `CDP_PORT` で決まる。移行が済んだら 9222 に寄せてもよい。

⚠️ 向こうの手順にある「使い終わったら CDP の `Browser.close` で閉じる」は、相乗りでは使えない。
共有ブラウザを閉じることになり、相手のタブも全部消える（compose の `restart` で立ち直るが、
開いていたページとログイン状態は戻らない）。閉じるのは自分が開いたページ（`close_page`）まで。

### 相乗りの作法（共有ブラウザで気をつけること）

ブラウザは1本なので、CDP に繋いだ MCP からは互いのものが見える。2026-10-25 に MCP を2本
順に繋いで確かめた。

- **タブは全員に見える。**`list_pages` に相手のタブも出て、`close_page` で閉じられる
  （相手が選択中のページを閉じると、相手の次の呼び出しがエラーになる）。
- **クッキーとストレージも共有。**既定のコンテキストで片方がログインすると、もう片方も
  ログイン状態で見える。
- **分けたいときは `new_page` の `isolatedContext` に名前を渡す。**別のブラウザコンテキスト
  （incognito 相当）が作られ、クッキーもストレージも既定のものと混ざらない（実測: 既定の
  コンテキストに置いたクッキーが `isolatedContext` のページでは空）。
- **`isolatedContext` の名前は MCP プロセスごと。**別の MCP が同じ名前を渡しても新しい
  コンテキストになり、相手のコンテキストは `isolated-context-1` のような自動の名前で見える。
  同じコンテキストを2つの MCP から共有する手段は無い（1.12.0）。
- **MCP を終えてもタブは残る。**繋ぐ形の MCP は終了時に `disconnect()` するだけで、開いた
  ページもコンテキストも閉じない（実測: MCP を抜けたあとも `/json/list` にタブが残る）。
  使い終わったら自分の分を `close_page` する。放っておくとタブが溜まってメモリを食う。
  最後の1枚は閉じられないので、`about:blank` を1枚残す形になる。
- ページを指す道具は `pageId` を要求する（`--pageIdRouting` が 1.12.0 の既定）。相手が
  タブを閉じると番号の並びが変わるので、操作の前に `list_pages` で引き直す。

## 構成

- `Dockerfile`: `node:22-bookworm-slim` + Debian chromium + `chrome-devtools-mcp`（arm64）。
  実行ユーザーは `node`（uid 1000）。
- `compose.yml`: `chrome`（常駐、CDP を 127.0.0.1:9223 に公開）と `mcp`（都度起動、stdio）
- `.env`: `MCP_VERSION` と `CDP_PORT`。chromium の版を固定したいときだけ `CHROMIUM_VERSION`
  を足す（Dockerfile のコメント参照。既定は空＝apt の最新）

## 注意（実測で踏んだこと）

- **ホストのネットワークを使っている**（`network_mode: host`）。chromium 本体
  （`--headless=new`）は `--remote-debugging-address` を読まず、常に 127.0.0.1（か ::1）に
  だけ束縛する（Chromium の `chrome/browser/devtools/remote_debugging_server.cc`）。ポート公開
  （docker-proxy）はコンテナ側の IP に繋ぎに行くので届かず、接続がリセットされる。host network に
  したらホストの `127.0.0.1:9223` からそのまま繋がった。
  代償として、**ブラウザで開いたページからホストの 127.0.0.1 のサービス（DB、検索、ローカルの
  API など）にも届く**。信用できないページを開くときは `isolatedContext` を使い、ホスト側の
  サービスは認証付きにしておく。
- **CDP の HTTP は Host ヘッダが IP か `localhost` でないと 500 を返す**
  （`Host header is specified and is not an IP address or localhost.`。Chromium の
  `content/browser/devtools/devtools_http_handler.cc`）。だから compose のサービス名
  （`http://chrome:9223`）では、名前が引けたとしても繋がらない。ポート番号は見ていない
  （`Host: 127.0.0.1:9999` で叩いても 200 が返り、`webSocketDebuggerUrl` もその Host をそのまま
  写す）。
- **sandbox は切っている**（`--no-sandbox`）。Docker 既定の seccomp が名前空間付きの `clone` を
  止めるため、Debian の `chromium-sandbox`（setuid 版）を入れて非 root で起こしても
  `Failed to move to new namespace: ... Operation not permitted` で落ちる（2026-10-25 実測）。
  その代わり、コンテナは **root でなく `node`（uid 1000）で動かし**、CDP は 127.0.0.1 にしか
  開けていない。sandbox を生かすなら Docker の seccomp プロファイルを差し替える
  （`security_opt: ["seccomp=<json>"]`）必要があり、未検証。
- `shm_size` は書かない。Debian の `/usr/bin/chromium` ラッパーが、`/dev/shm` が 3.8GB 未満だと
  自分で `--disable-dev-shm-usage` を足す（`/etc/chromium.d/` の設定）ので、1GB の shm を
  用意しても使われない。共有メモリは `/tmp`（overlay）に置かれる。
- メモリの天井は `mem_limit: 3g`。超えると中の一番大きいプロセス（たいていレンダラ）が OOM で
  落ちる。ブラウザ本体が落ちれば `restart: unless-stopped` で戻るが、タブは消える。
- 実測（2026-10-25）: イメージ 1.54GB、コンテナのメモリ 165MB、`/json/version` は
  `Chrome/156.0.8078.47` を返す（bookworm-security の版。bookworm 本体は 150.0.7871.100）。
  MCP を `docker run -i` でも `docker compose run --rm -T mcp` でも繋ぐと 32 ツールが見えた
  （`click` / `evaluate_script` / `lighthouse_audit` など）。
- `--user-data-dir` は `/tmp/chrome-profile`。コンテナを作り直すとログイン状態などは消える。
  残したいものが出てきたら named volume に移す。
- メモリは idle で PSS 270MB 前後（ホスト直実行の同じ構成で実測）。`--renderer-process-limit=4`
  と `--js-flags=--max-old-space-size=512` は「1 と 256」から上げた。1 だと全タブが1レンダラに
  乗って片方の重いページがもう片方を巻き込み、256 だと重い SPA で `Out of Memory` になるため。
