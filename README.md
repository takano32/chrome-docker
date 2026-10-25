# chrome-docker

[chrome-devtools-mcp](https://github.com/ChromeDevTools/chrome-devtools-mcp) と、それが喋る相手の
headless Google Chrome を1つのイメージに入れて、ブラウザだけを compose で常駐させる。

狙いは「ブラウザを1本だけ立てて、複数のボットが CDP で相乗りする」。各自が自分の chrome を
起動するとプロセスもメモリも二重になり、逆に他人のブラウザに相乗りすると「相手が先に起動して
いる」依存ができる。第三の常駐にして、どちらのボットの再起動にも振り回されないようにする。

本家リポジトリは clone も改変もしない。`npm install -g chrome-devtools-mcp@<版>` で入れるだけ。
版は `.env` の `MCP_VERSION`（2026-10-25 時点の最新 1.12.0）。
Chrome は Google の apt リポジトリの `google-chrome-stable`（arm64 版が 2026-10-25 時点で配られている。
`dists/stable/Release` の `Architectures: amd64 arm64` で確認）。

## 前提

- docker（この箱は 29.9.2）と compose plugin（v5.6.1 で確認）。
- イメージは arm64 で作る。Google の apt リポジトリは amd64 と arm64 の両方を持つので、
  `dpkg --print-architecture` に合わせて同じ Dockerfile で作れる（amd64 は未検証）。

## 使い方

```bash
cd ~/opt/chrome-docker
docker compose up -d --build     # 初回はビルド（Chrome + MCP）
docker compose ps
curl -s http://127.0.0.1:9223/json/version   # CDP が返れば成功
docker run --rm --entrypoint /opt/google/chrome/chrome chrome-docker:local --version   # 入っている Chrome の版
```

止める・消す:

```bash
docker compose down            # ブラウザを止める（イメージは残る）
docker compose down --rmi local  # イメージも消す
```

Chrome の更新を取り込む（apt の層はビルドキャッシュに残るので `--build` だけでは更新されない）:

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
繋いで確かめた。

- **タブは全員に見える。**`list_pages` に相手のタブも出て、`close_page` で閉じられる
  （相手が使っているページを閉じると、相手の次の操作が失敗する）。
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
- ページを指す道具は `pageId` を要求する（`--pageIdRouting` が 1.12.0 の既定）。番号は MCP
  プロセスごとに振られ、同じタブでも相手の MCP では別の番号になる。相手がタブを閉じると
  番号ごと消えるので、操作の前に `list_pages` で引き直す。

### 2つのボットで同時に使うとどうなるか（2026-10-25 実測）

MCP を2本同時に繋ぎ、片方（A）が開いたものをもう片方（B）がどこまで見られ、触れるかを測った。
`isolatedContext` は**状態の仕切りであって、守りの壁ではない**。

- **B は A の `isolatedContext` のページを読める。**`list_pages` に A のページが
  `isolated-context-N` の名で出て、その `pageId` を渡せば `evaluate_script` で DOM の文字列も
  `document.cookie` も取れ、`take_screenshot` で画面も撮れ、`navigate_page` で別の URL へ飛ばせ、
  `close_page` で閉じられる（全部、MCP のツールだけでできた）。
- **CDP に直接繋げば、さらに素通し。**127.0.0.1:9223 に繋いだどのプロセスも
  `Target.getBrowserContexts` で全コンテキストを列挙でき、`Target.attachToTarget` で相手の
  ページに付け、`Storage.getCookies` に `browserContextId` を渡せば相手のコンテキストの
  クッキーが返る（実測で A のクッキーが取れた）。`Browser.close` で全部を閉じることもできる。
- **分かれているもの**: クッキーとストレージ（コンテキストごと）、`emulate` の UA や
  `resize_page` の大きさ（ページごと。A が自分のページに掛けた上書きは B 自身のページには
  及ばない。B が A のページを見ると A の上書きが見える）。
- **ぶつかるもの**: `performance_start_trace` はブラウザ全体で1本。A が録っている間に B が
  始めると `Tracing has already been started (possibly in another tab)` で失敗する。
  `lighthouse_audit` も中でトレースを使い、既定で対象ページを reload し、その origin の
  service worker と cache storage を消してブラウザキャッシュも消す（同梱の Lighthouse の既定。
  同じ既定コンテキストで同じ origin を使っていれば相手の分も消える。別コンテキストに及ぶかは未検証）。
- **巻き込まれないもの**: A のページで JS がヒープを食い潰しても（512MB の上限）、B のページは
  生きていてブラウザも落ちなかった。ただし A 側の MCP はその呼び出しから先が全部タイムアウトに
  なる（ツールの呼び出しが直列なので、詰まった1件が後ろを塞ぐ）。
- **ブラウザの再起動**: `docker compose restart chrome` の最中に繋いでいた MCP は、次の呼び出しで
  自動で繋ぎ直し、`Note: the browser was restarted or reconnected since the last call` を返す。
  ただし開いていたページもコンテキストもクッキーも全部消える（相手の分も）。
- `--renderer-process-limit=4` は固い上限ではない。コンテキストが違うとレンダラを共有できないので、
  コンテキスト5つにページ6枚でレンダラは 10 本になった。
- 未検証: DNS キャッシュとソケットプールの共有（network service の中なので共有と見ている）、
  HTTP 認証キャッシュ、ダウンロード先（MCP は `Browser.setDownloadBehavior` を呼ばないので
  プロファイル既定の場所に落ちると見ている）、`mem_limit` に当たったとき OOM killer が
  どのプロセスを選ぶか。

**結論。**今の構成は「ブラウザ1本＝信頼の単位1つ」で、2つのボットは互いに全部を読め、
全部を壊せる。相手のページに書かれた指示（プロンプトインジェクション）が、相手のボットを通して
こちらのタブを読む・閉じる経路もある。だから、同時に使ってよいのは**公開ページを読むだけで、
相手に見えて困らない用途**まで。**ログインしたまま使う**（既定コンテキストならクッキーが相手にも
効く。`isolatedContext` でも CDP 経由で取れる）、**会話の中身を映す URL やページを開く**
（nilkani06 のチャンネル分離の規則に反する）、**途中で止められては困る長い操作**
（トレース、Lighthouse、再起動）には使わない。

代替案（トレードオフ付き）:

- **ボットごとに MCP が自分の Chrome を起こす**（chrome-devtools-mcp の既定の形。このイメージなら
  `docker run -i --rm chrome-docker:local --headless --isolated --chromeArg=--no-sandbox` で、
  ポートを開けずに pipe で繋ぐ）。相手からは見えないし、落ちても相手に及ばない。代わりに
  MCP の起動ごとに Chrome も起動し（数秒、200MB 前後）、MCP を抜けると状態も消える。
  「常駐1本で相乗り」という当初の狙いは捨てることになる。未検証（起動の引数は上流の既定）。
- **ボットごとにブラウザを常駐させる**（同じイメージで `chrome` サービスを2つ、別ポート、別
  `user-data-dir`）。プロセスも状態も分かれ、片方の再起動が相手に及ばない。代わりにメモリが
  2倍で、127.0.0.1 のポートはどちらからも届くので「相手を覗かない」は約束に頼る。
- **今の1本を `isolatedContext` の約束で使う**（現状）。いちばん軽いが、上に書いたとおり
  守りは無い。
- **CDP の前に転送役を置いてコンテキストを強制する**（接続ごとに `browserContextId` を縛る
  プロキシ）。守りは作れるが、CDP の全メソッドを解釈する自作物になり、版が上がるたびに
  追従が要る。既製品（browserless など）もあるが未検証。

## 構成

- `Dockerfile`: `node:22-bookworm-slim` + Google Chrome（Google の apt リポジトリ。署名鍵は
  `/etc/apt/keyrings/google-chrome.asc` に置き `signed-by` でそのリポジトリにだけ使う）
  + `chrome-devtools-mcp`。実行ユーザーは `node`（uid 1000）。
- `compose.yml`: `chrome`（常駐、CDP を 127.0.0.1:9223 に公開）と `mcp`（都度起動、stdio）
- `.env`: `MCP_VERSION` と `CDP_PORT`。Chrome の版を固定したいときだけ `CHROME_VERSION`
  を足す（Dockerfile のコメント参照。既定は空＝apt の最新）

## 注意（実測で踏んだこと）

- **ホストのネットワークを使っている**（`network_mode: host`）。Chrome 本体
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
  止めるため、Chrome 同梱の `chrome-sandbox`（setuid root。`/opt/google/chrome/chrome-sandbox`）
  があっても、非 root で起こすと
  `Failed to move to new namespace: ... Operation not permitted` で落ちる（2026-10-25 実測）。
  その代わり、コンテナは **root でなく `node`（uid 1000）で動かし**、CDP は 127.0.0.1 にしか
  開けていない。sandbox を生かすなら Docker の seccomp プロファイルを差し替える
  （`security_opt: ["seccomp=<json>"]`）必要があり、未検証。
- `--disable-dev-shm-usage` を明示している。Docker の `/dev/shm` は既定 64MB で、Chrome の
  共有メモリには足りない。共有メモリは `/tmp`（overlay）に置かれる。`shm_size` を数 GB にして
  `/dev/shm` を使わせる手もある。
- メモリの天井は `mem_limit: 3g`。超えると中の一番大きいプロセス（たいていレンダラ）が OOM で
  落ちる。ブラウザ本体が落ちれば `restart: unless-stopped` で戻るが、タブは消える。
- Chrome の deb の postinst は、自分の apt 設定（`google-chrome.sources`）を足そうとする。
  `/etc/default/google-chrome` に `repo_add_once="false"` を先に書いて止めてある。署名鍵の写し
  `/usr/share/keyrings/google-chrome.gpg` は postinst が無条件に置く（害は無い）。
- 実測（2026-10-25）: イメージ 1.44GB（Debian の chromium で作っていたときは 1.54GB）、
  コンテナのメモリは idle で 160MB 前後、`/json/version` は `Chrome/156.0.8078.47` を返す
  （この文字列は Chromium でも同じ。製品名は `navigator.userAgentData.brands` に
  `Google Chrome` が出ることで見分けた）。MCP を `docker run -i` でも
  `docker compose run --rm -T mcp` でも繋ぐと 32 ツールが見えた（`click` / `evaluate_script` /
  `lighthouse_audit` など）。日本語ページのスクリーンショットも豆腐にならない（`fonts-noto-cjk`）。
- `--user-data-dir` は `/tmp/chrome-profile`。コンテナを作り直すとログイン状態などは消える。
  残したいものが出てきたら named volume に移す。
- `--renderer-process-limit=4` と `--js-flags=--max-old-space-size=512` は「1 と 256」から上げた。
  1 だと全タブが1レンダラに乗って片方の重いページがもう片方を巻き込み、256 だと重い SPA で
  `Out of Memory` になるため。
- 版の固定: Google のリポジトリも最新版しか置かない（stable / beta / unstable が各1つ）ので、
  `CHROME_VERSION` で固定した版は次の更新で消え、ビルドが止まる。止めて人が上げる運用なら固定、
  更新を自動で取り込むなら空のまま（既定）。
