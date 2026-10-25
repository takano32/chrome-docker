# chrome-docker

[chrome-devtools-mcp](https://github.com/ChromeDevTools/chrome-devtools-mcp) と、それが起こす
headless Google Chrome を1つのイメージに入れたもの。

既定の使い方は **MCP の接続1本ごとにコンテナを1つ起こし、その中で MCP が自分の Chrome を起こす**。
ポートは開かず、相手のボットからは見えない。抜けるとコンテナごと消える。
2つのボット（Hermes と nilkani06）が同じ箱に同居しても、互いのタブもクッキーも見えない。

1本のブラウザを常駐させて複数の MCP で相乗りする形も残してある（compose の profile `shared`）。
ログイン状態を残したいときや、1本を共有したいとき用。相乗りの性質（相手のタブもクッキーも
見える）は下の「常駐ブラウザに相乗りする」を読んでから使う。

本家リポジトリは clone も改変もしない。`npm install -g chrome-devtools-mcp@latest` で入れるだけ。
Chrome は Google の apt リポジトリの `google-chrome-stable`（arm64 版が 2026-10-25 時点で配られている。
`dists/stable/Release` の `Architectures: amd64 arm64` で確認）。

## 前提

- docker（この箱は 29.9.2）と compose plugin（v5.6.1 で確認）。
- イメージは arm64 で作る。Google の apt リポジトリは amd64 と arm64 の両方を持つので、
  `dpkg --print-architecture` に合わせて同じ Dockerfile で作れる（amd64 は未検証）。

## ビルドと版

```bash
cd ~/opt/chrome-docker
docker compose build                    # chrome-docker:local を作る
docker run --rm --entrypoint /opt/google/chrome/chrome chrome-docker:local --version   # Chrome の版
docker run --rm chrome-docker:local --version                                          # MCP の版
```

版は固定しない。Chrome は Google のリポジトリの stable、chrome-devtools-mcp は npm の latest が入る。
固定したいときだけ `.env` に `CHROME_VERSION=156.0.8078.47-1` や `MCP_VERSION=1.12.0` を書く
（Dockerfile のコメント参照。Google のリポジトリも最新版しか置かないので、固定した Chrome の版は
次の更新で消え、ビルドが止まる）。

更新を取り込むには `--no-cache` が要る。apt の層も npm の層もビルドキャッシュに残るので、
`docker compose build` だけでは新しい版が入らない:

```bash
docker compose build --no-cache
```

## 使い方（既定: 接続ごとに Chrome を起こす）

MCP サーバは stdio。クライアント（Hermes、Claude Code）がその都度 `docker run -i` で起こす。
引数を渡さなければ Dockerfile の CMD（`--headless --isolated --chromeArg=--no-sandbox
--chromeArg=--js-flags=--max-old-space-size=512 --no-usage-statistics --no-performance-crux`）が効き、
MCP がコンテナの中で `/opt/google/chrome/chrome` を起こして pipe で繋ぐ（`--executablePath` は要らない）。

```bash
docker run -i --rm --init --memory 2g chrome-docker:local
```

- `--init`: PID 1 を docker-init にして、孤児の回収と SIGTERM の配達を任せる。
- `--memory 2g`: コンテナ（MCP + Chrome 1本）の天井。1ページの V8 ヒープは CMD で 512MB に抑えてある。
- `--shm-size` は要らない（MCP が Chrome に `--disable-dev-shm-usage` を渡す）。`--user` も要らない
  （イメージが `node` で動く）。
- 足しても動くことを確かめたもの: `--cap-drop ALL --security-opt no-new-privileges --pids-limit 512`。

Hermes の登録例:

```bash
hermes mcp add chrome-devtools \
  --command docker \
  --args run -i --rm --init --memory 2g chrome-docker:local
```

nilkani06 の登録例（`~/.claude.json` の `projects["/home/takano32/nilkani06"].mcpServers`）:

```json
"chrome-devtools": {
  "type": "stdio",
  "command": "docker",
  "args": ["run", "-i", "--rm", "--init", "--memory", "2g", "chrome-docker:local"]
}
```

この形では「使い終わったら CDP の `Browser.close` で閉じる」手順も、そのための
`--chromeArg=--remote-debugging-port=9222` も要らない。MCP が抜けると Chrome もコンテナも消える。

compose から試すなら `docker compose run --rm -T mcp`（同じ既定）。

### nilkani06 側の置き換え（9222 をこの形に替える手順。まだやっていない）

いまの登録は `bunx --bun chrome-devtools-mcp@latest --headless --isolated ...
--chromeArg=--remote-debugging-port=9222` で、Chrome をホストに起こし、9222 を「閉じるための窓口」
にしている（`.agents/skills/browser/mcp.md`）。これを上の `docker run` に置き換える手順:

1. `docker compose build` でイメージを作る（済）。常駐の試験は 9223 のままで、9222 には触らない。
2. `~/.claude.json` の local 登録を上の JSON に書き換える（`command` を `docker`、`args` を
   `run -i --rm --init --memory 2g chrome-docker:local`）。
3. `/quit` で立ち上げ直し、`claude mcp list` で `✔ Connected` を見る。
4. 使ってみて `docker ps --filter ancestor=chrome-docker:local` にセッション分のコンテナが出ること、
   セッションが終わると消えることを見る。

閉じ方は変わる。9222 の窓口は要らない。MCP は stdin が閉じる（セッションが終わる）と自分で
Chrome を閉じ、コンテナは `--rm` で消える（実測: 抜けた直後に `docker ps -a` に残り 0）。
強制終了は `docker stop <コンテナ>`。コンテナの中で `--chromeArg=--remote-debugging-port=9222`
を開けても、bridge ではホストから届かない（Chrome は 127.0.0.1 にしか束縛しないので
`-p` でも届かず、`--network host` が要る）ので、窓口としては使えない。
`mcp.md` の「`--isolated` を外すとポートが死ぬ」もこの形には関係ない（ポートを使わない）。

Claude Code はセッション（委譲先を含む）ごとに MCP を1本持つので、コンテナもその数だけ立つ
（2026-10-25 時点で bunx の MCP が4本居た＝約 260MB × 4）。いまの形も Chrome を4本起こして
いるので総量は同程度。

まだ確かめていないこと: Claude Code の登録から実際に起こしたときの接続（ここでの実測は自作の
stdio クライアントと Hermes 相当の `docker run`）、`claude mcp list` の表示、委譲先からの
同時起動の数が増えたときの挙動。

ネットワークは既定の bridge。外のサイトには出られる。ホストの 127.0.0.1 で待つサービス
（DB、ローカルの API）には届かない（`net::ERR_CONNECTION_REFUSED`。コンテナ自身の loopback になる）。
ただし **0.0.0.0 で待つホストのサービスには docker0 の IP（この箱は 172.17.0.1）経由で届く**
（実測: 18080 の検索には 200、127.0.0.1 だけの 9999 と 5432 は `EHOSTUNREACH`）。

MCP がファイルを書くツール（`take_screenshot` の `filePath`、`performance_start_trace` の
`filePath` など）は、クライアントが roots を渡さないと OS の一時ディレクトリにしか書けず、
それはコンテナの中なので `--rm` で消える。残したければ `-v <ホストの dir>:/out` を足して
`--workspace /out` を渡し、`/out` の下のパスを指定する（返り値に画像を含めるツールはそのまま使える）。

### 実測（2026-10-25、接続ごとの形）

- 最初のツール呼び出しが返るまで 1.8〜2.9 秒（Chrome の起動込み）。
- コンテナ1つのメモリは、ページ3枚で 280MB 前後（MCP の node と Chrome を合わせて）。
- 2本同時に起こすと、`list_pages` に相手のページは出ず、クッキーも別、`performance_start_trace`
  は両方同時に録れる。片方のページで JS がヒープを食い潰しても、そのコンテナが自分の天井
  （2GB）に当たるだけで、もう片方は無傷。片方が抜けても相手は無傷。
- 抜けたあとコンテナは残らない（`--rm`）。Chrome もコンテナと一緒に消える。
- 日本語ページのスクリーンショットは豆腐にならない（`fonts-noto-cjk`）。

## 任意: 常駐ブラウザに相乗りする（profile `shared`）

```bash
docker compose --profile shared up -d chrome       # ブラウザを常駐させる
curl -s http://127.0.0.1:9223/json/version         # CDP が返れば成功
docker compose --profile shared run --rm -T mcp-shared   # それに相乗りする MCP（stdio）
docker compose --profile shared down               # 止める
```

Hermes や nilkani06 から相乗りするときは、引数を全部渡して CMD を差し替える:

```bash
docker run -i --rm --network host chrome-docker:local \
  --browserUrl http://127.0.0.1:9223 \
  --no-usage-statistics --no-performance-crux
```

`--network host` はホストの 127.0.0.1:9223 に繋ぐため。ブラウザ側は 127.0.0.1 にしか
待ち受けていないので、外からは触れない。ポートは `.env` の `CDP_PORT` で決まる。

**`--headless` と `--isolated` は付けない。**どちらも「MCP が自分で Chrome を起こすとき」の
引数で、`--browserUrl` で繋ぐ形では読まれない（1.12.0 の `BrowserManager.js` の `#connect` は
`browserUrl` / `wsEndpoint` / `wsHeaders` しか見ない。`--chromeArg` も同じ）。付けても隔離には
ならないことを実測した。隔離は下の `isolatedContext` で取る。

⚠️ 相乗りでは「使い終わったら CDP の `Browser.close` で閉じる」は使えない。共有ブラウザを
閉じることになり、相手のタブも全部消える（compose の `restart` で立ち直るが、開いていたページと
ログイン状態は戻らない）。閉じるのは自分が開いたページ（`close_page`）まで。

### 相乗りの作法（共有ブラウザで気をつけること）

ブラウザは1本なので、CDP に繋いだ MCP からは互いのものが見える。2026-10-25 に MCP を2本
繋いで確かめた。

- **タブは全員に見える。**`list_pages` に相手のタブも出て、`close_page` で閉じられる
  （相手が使っているページを閉じると、相手の次の操作が失敗する）。
- **クッキーとストレージも共有。**既定のコンテキストで片方がログインすると、もう片方も
  ログイン状態で見える。
- **分けたいときは `new_page` の `isolatedContext` に名前を渡す。**別のブラウザコンテキスト
  （incognito 相当）が作られ、クッキーもストレージも既定のものと混ざらない。
- **`isolatedContext` の名前は MCP プロセスごと。**別の MCP が同じ名前を渡しても新しい
  コンテキストになり、相手のコンテキストは `isolated-context-1` のような自動の名前で見える。
- **MCP を終えてもタブは残る。**繋ぐ形の MCP は終了時に `disconnect()` するだけで、開いた
  ページもコンテキストも閉じない。使い終わったら自分の分を `close_page` する。
  最後の1枚は閉じられないので、`about:blank` を1枚残す形になる。
- ページを指す道具は `pageId` を要求する（`--pageIdRouting` が 1.12.0 の既定）。番号は MCP
  プロセスごとに振られ、相手がタブを閉じると番号ごと消えるので、操作の前に `list_pages` で引き直す。

### 2つのボットで同時に使うとどうなるか（2026-10-25 実測）

MCP を2本同時に繋ぎ、片方（A）が開いたものをもう片方（B）がどこまで見られ、触れるかを測った。
Chrome 版と Debian の chromium 版（同じ 156.0.8078.47）で結果は同じ。
`isolatedContext` は**状態の仕切りであって、守りの壁ではない**。

- **B は A の `isolatedContext` のページを読める。**`list_pages` に A のページが
  `isolated-context-N` の名で出て、その `pageId` を渡せば `evaluate_script` で DOM の文字列も
  `document.cookie` も取れ、`take_screenshot` で画面も撮れ、`navigate_page` で別の URL へ飛ばせ、
  `close_page` で閉じられる（全部、MCP のツールだけでできた）。
- **CDP に直接繋げば、さらに素通し。**127.0.0.1:9223 に繋いだどのプロセスも
  `Target.getBrowserContexts` で全コンテキストを列挙でき、`Target.attachToTarget` で相手の
  ページに付け、`Storage.getCookies` に `browserContextId` を渡せば相手のコンテキストの
  クッキーが返る。`Browser.close` で全部を閉じることもできる。
- **分かれているもの**: クッキーとストレージ（コンテキストごと）、`emulate` の UA や
  `resize_page` の大きさ（ページごと。A が自分のページに掛けた上書きは B 自身のページには
  及ばない。B が A のページを見ると A の上書きが見える）。
- **ぶつかるもの**: `performance_start_trace` はブラウザ全体で1本。A が録っている間に B が
  始めると `Tracing has already been started (possibly in another tab)` で失敗する。
  `lighthouse_audit` も中でトレースを使い、既定で対象ページを reload し、その origin の
  service worker と cache storage を消してブラウザキャッシュも消す（同梱の Lighthouse の既定。
  別コンテキストに及ぶかは未検証）。
- **巻き込まれないもの**: A のページで JS がヒープを食い潰しても（512MB の上限）、B のページは
  生きていてブラウザも落ちなかった。ただし A 側の MCP はその呼び出しから先が全部タイムアウトに
  なる（ツールの呼び出しが直列なので、詰まった1件が後ろを塞ぐ）。
- **ブラウザの再起動**: `docker compose restart chrome` の最中に繋いでいた MCP は、次の呼び出しで
  自動で繋ぎ直し、`Note: the browser was restarted or reconnected since the last call` を返す。
  ただし開いていたページもコンテキストもクッキーも全部消える（相手の分も）。
- `--renderer-process-limit=4` は固い上限ではない。コンテキストが違うとレンダラを共有できないので、
  コンテキスト5つにページ6枚でレンダラは 10 本になった。
- 未検証: DNS キャッシュとソケットプールの共有、HTTP 認証キャッシュ、ダウンロード先、
  `mem_limit` に当たったとき OOM killer がどのプロセスを選ぶか。

**結論。**常駐1本は「ブラウザ1本＝信頼の単位1つ」で、2つのボットは互いに全部を読め、
全部を壊せる。相手のページに書かれた指示（プロンプトインジェクション）が、相手のボットを通して
こちらのタブを読む・閉じる経路もある。同時に使ってよいのは**公開ページを読むだけで、相手に
見えて困らない用途**まで。ログインしたまま使う、会話の中身を映す URL やページを開く、途中で
止められては困る長い操作（トレース、Lighthouse、再起動）には使わない。
だから既定を「接続ごとに Chrome を起こす」形にした（上の「使い方」）。

## 構成

- `Dockerfile`: `node:24-bookworm-slim` + Google Chrome（Google の apt リポジトリ。署名鍵は
  `/etc/apt/keyrings/google-chrome.asc` に置き `signed-by` でそのリポジトリにだけ使う）
  + `chrome-devtools-mcp`。実行ユーザーは `node`（uid 1000）。ENTRYPOINT は MCP、CMD は
  「自分で Chrome を起こす」既定の引数。
- `compose.yml`: `mcp`（既定。接続ごとに起こす）、`chrome`（profile `shared`。常駐、CDP を
  127.0.0.1:9223 に公開）、`mcp-shared`（profile `shared`。常駐に相乗り）
- `.env`: `CDP_PORT`（常駐の CDP ポート）。版を固定したいときだけ `CHROME_VERSION` と
  `MCP_VERSION` を足す（既定は空＝最新）

## 注意（実測で踏んだこと）

- **常駐（profile `shared`）はホストのネットワークを使う**（`network_mode: host`）。Chrome 本体
  （`--headless=new`）は `--remote-debugging-address` を読まず、常に 127.0.0.1（か ::1）に
  だけ束縛する（Chromium の `chrome/browser/devtools/remote_debugging_server.cc`）。ポート公開
  （docker-proxy）はコンテナ側の IP に繋ぎに行くので届かず、接続がリセットされる。host network に
  したらホストの `127.0.0.1:9223` からそのまま繋がった。
  代償として、**ブラウザで開いたページからホストの 127.0.0.1 のサービスにも届く**。既定の
  「接続ごとに起こす」形は bridge なので、この問題は無い（0.0.0.0 で待つサービスには届く。上の「使い方」）。
- **CDP の HTTP は Host ヘッダが IP か `localhost` でないと 500 を返す**
  （`Host header is specified and is not an IP address or localhost.`。Chromium の
  `content/browser/devtools/devtools_http_handler.cc`）。だから compose のサービス名
  （`http://chrome:9223`）では、名前が引けたとしても繋がらない。ポート番号は見ていない。
- **sandbox は切っている**（`--no-sandbox`）。Docker 既定の seccomp が名前空間付きの `clone` を
  止めるため、Chrome 同梱の `chrome-sandbox`（setuid root。`/opt/google/chrome/chrome-sandbox`）
  があっても、非 root で起こすと
  `Failed to move to new namespace: ... Operation not permitted` で落ちる（2026-10-25 実測）。
  その代わり、コンテナは **root でなく `node`（uid 1000）で動かし**、既定の形ではポートを開けず、
  常駐でも CDP は 127.0.0.1 にしか開けていない。sandbox を生かすなら Docker の seccomp
  プロファイルを差し替える（`security_opt: ["seccomp=<json>"]`）必要があり、未検証。
- `--disable-dev-shm-usage` を使う（既定の形は MCP が渡し、常駐は compose に明示）。Docker の
  `/dev/shm` は既定 64MB で、Chrome の共有メモリには足りない。共有メモリは `/tmp`（overlay）に
  置かれる。`shm_size` を数 GB にして `/dev/shm` を使わせる手もある。
- Chrome の deb の postinst は、自分の apt 設定（`google-chrome.sources`）を足そうとする。
  `/etc/default/google-chrome` に `repo_add_once="false"` を先に書いて止めてある。署名鍵の写し
  `/usr/share/keyrings/google-chrome.gpg` は postinst が無条件に置く（害は無い）。
- 常駐の実測（2026-10-25）: イメージ 1.44GB（Debian の chromium で作っていたときは 1.54GB）、
  コンテナのメモリは idle で 160〜220MB、`/json/version` は `Chrome/156.0.8078.47` を返す
  （この文字列は Chromium でも同じ。製品名は `navigator.userAgentData.brands` に
  `Google Chrome` が出ることで見分けた）。
- 常駐の `--user-data-dir` は `/tmp/chrome-profile`。コンテナを作り直すとログイン状態などは消える。
  残したいものが出てきたら named volume に移す。
- 常駐の `--renderer-process-limit=4` と `--js-flags=--max-old-space-size=512` は「1 と 256」から
  上げた。1 だと全タブが1レンダラに乗って片方の重いページがもう片方を巻き込み、256 だと重い SPA で
  `Out of Memory` になるため。
