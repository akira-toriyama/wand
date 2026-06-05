# wand

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![swift](https://img.shields.io/badge/Swift-6.0-orange)
![license](https://img.shields.io/badge/license-MIT-blue)

[English](README.md) · **日本語**

macOS 用のグローバルマウスジェスチャーデーモン。マウスのボタンを
押したままカーソルで短い形 — 下、そして右 — を描くと、wand が
アクションを実行する: タブを閉じる、開き直す、ウィンドウを最小化、
シェルコマンドを走らせる。アクションは **描き始めた時にカーソルが
乗っていたウィンドウ** に対して実行される。

## ジェスチャー

トリガーボタン(デフォルトは右ボタン)を押したまま描く。1 ストロークは
方向の並び:

```
L = 左    U = 上    R = 右    D = 下
```

`DR` は 下→右、`URD` は 上→右→下。ボタンを離すと wand が形を
ルールと照合し、最初にマッチしたものを実行する。何にもマッチしない形
(またはほとんど動いていない)は何も起きず、普通のクリックは普通の
クリックとして動く。

デフォルト(同梱の [`config.toml`](config.toml)):

| 描く | アクション | 対象 |
|---|---|---|
| `DR` 下 → 右 | 現在のタブを閉じる(`cmd+w`) | Chrome / Safari |
| `UR` 上 → 右 | 直前に閉じたタブを復元(`cmd+shift+t`) | Chrome / Safari |
| `DRU` 下 → 右 → 上 | ウィンドウを閉じる | 全アプリ |
| `L` 左 | ウィンドウを最小化 | 全アプリ |

描いている間、半透明の軌跡がカーソルに追従する — 今の形がルールに
マッチしていれば match 色、そうでなければ no-match 色。カーソル周りに、
**ここから到達できるルール**が *次に必要な方向側* に配置される小さな
カードで出て、いま離せば発動するものは match 色で塗られる。ストローク
開始位置には **対象アプリのアイコン**のバッジが出るので、キーボード
フォーカスが別ウィンドウでも「どのウィンドウに作用するか」が一目で
分かる。

色・太さ・on/off と各パーツのトグル(badge / blur / size / anim)は
`config.toml` の `[gesture.overlay]` で設定。

ヒントカードには退場アニメーションも付けられる — drop / slide /
explode / vibrate / fireworks / confetti(花火・紙吹雪)。
ジェスチャー途中にカードが到達不能になった瞬間(`card-unmatch`)と、
ボタンを離してルールが発動した瞬間(`card-match`)それぞれに別の
効果を `[gesture.overlay]` で割り当てられる。既定はどちらも無し
(静かに消える)。overlay を off にしても効くカーソル位置のエフェクト
(trail-end burst と post-fire decal)は別軸の `[gesture.fire]` 配下。

アクションは **カーソル直下のウィンドウ** を対象にする(キーボード
フォーカスを持つウィンドウではない): `ax` はそのウィンドウを直接
操作、`key` は raise してからキーを送る、`shell` はそのウィンドウの
識別子(bundle id, pid, title, frame)を環境変数で受け取る。

## ランチャー(opt-in)

wand は **中ボタンクリックで出るコンテキストメニュー** も第二の
トリガーとして持っている。既定で off。`[launcher].enabled = true`
にすると、ジェスチャー用 event tap と別にもう一つの tap を立ち上げる。
ランチャーは **non-activating panel** で描画される(PopClip 同等):
下のアプリの**キーボードフォーカスを奪わず**に上に浮かぶので、エディタ
で typing を続けたままマウスで行を選べる。サブメニュー(`group =
["..."]`)は hover で隣に child panel として開く。外をクリック / Esc
で閉じる。Panel は **ボタン押下時にカーソル直下にあったウィンドウ** に
対して発動する — ジェスチャーと同じ不変条件。各 `[[launcher.item]]`
が 1 行:

```toml
[launcher]
enabled = true
button = "middle"                 # "middle" / "side1" / "side2" / "right"

[[launcher.item]]
name = "新規タブ"
icon = "🌐"                        # emoji / SF:<name> / ファイルパス
apps = ["*chrome*", "*safari*"]
action-type = "key"
action-keys = "cmd+t"

[[launcher.item]]
name = "名前順"
icon = "SF:textformat.abc"         # macOS SF Symbol
group = ["並び替え"]               # 「並び替え」サブメニュー配下
separator-before = true            # 行の上にセパレータ
action-type = "shell"
action-cmd = "echo name"
```

`icon` の書式: `"🌐"`(絵文字 / 1〜2 文字テキスト)、`"SF:globe"`
(SF Symbol — macOS 11+)、`"~/icons/foo.png"` または
`"icons/foo.png"`(相対パスは `~/.config/wand/` 基準)、
`"/abs/path.png"`(絶対パス)。解決できない値はアイコンなしに
フォールバック(`/tmp/wand.log` にログ)。

アイテムは **動的サブメニュー** にもできる。`dynamic` にシェル
コマンドを指定し、`template-*` を埋めると、stdout の各行が `{line}`
置換された子アイテムになる:

```toml
[[launcher.item]]
name = "ブランチ切替"
icon = "SF:point.3.connected.trianglepath.dotted"
dynamic = 'cd ~/repo && git branch --format="%(refname:short)"'
template-name = "{line}"
template-icon = "SF:arrow.triangle.branch"
template-action-type = "shell"
template-action-cmd  = 'cd ~/repo && git switch "{line}"'
```

シェルは 500ms でタイムアウト kill、空 / エラー / タイムアウト時は
disabled プレースホルダ(`(no items)` / `(error: exit N)` /
`(timeout)`)。`{line}` 内容は untrusted なのでシェルコマンド側で
必ずクオート(`"{line}"`)。

アイテムに **チェックマーク** も付けられる:

```toml
[[launcher.item]]
name = "ダークモード"
state = "shell:defaults read -g AppleInterfaceStyle 2>/dev/null | grep -q Dark"
action-type = "shell"
action-cmd  = "..."
```

`state` は静的に `"on"` / `"off"` / `"mixed"`、または
`"shell:<cmd>"` で menu-open ごとに評価(exit 0 → ✓、100ms
タイムアウト)。

`apps = ["*"]`(または `apps` 省略)の **グローバルアイテムは
Dock / メニューバー / Desktop でも発動**する — カーソル直下に
AX target が無い場所でも menu が出る(アプリ特定アイテムは
自動で除外)。Spotlight / 画面ロック / "ターミナルを開く" 等の
システム横断機能の置き場として最適。

### 選択テキストを使う shell アイテム(`$SELECTION`)

shell アクションには、中ボタン押下時にフォーカス要素で選択されて
いたテキストが `$SELECTION` 環境変数として渡される。何も選択して
いない、または対象アプリが AX に選択テキストを露出していない場合
は空。翻訳 / 検索 / 他アプリへ渡す系のワークフローに使える:

```toml
[[launcher.item]]
name = "Translate"
icon = "SF:globe"
action-type = "shell"
action-cmd = 'open "https://translate.google.com/?sl=auto&tl=en&text=$(printf %s "$SELECTION" | sed "s/ /%20/g")"'
```

shell コマンド内では必ず `"$SELECTION"` のようにクオートする —
内容はユーザーがハイライトした任意の文字列(URL / コード / shell
メタ文字を含みうる)で、`WAND_TARGET_TITLE` と同じく **untrusted**。

### 条件フィルタ(`filter-title` / `filter-shell`)

`apps` で「どのアプリの行か」を決め、**`filter-title`** で
ウィンドウタイトルを glob 絞り込み、**`filter-shell`** で
何でもありの shell 述語を評価する。`[[gesture.rule]]` /
`[[launcher.item]]` どちらでも使える:

```toml
[[launcher.item]]
name = "Issue を PR にする"
icon = "SF:arrow.triangle.pull"
apps = ["*chrome*"]
filter-title = "*github.com*/issues/*"      # GitHub Issue のときだけ
action-type = "url"
action-url = "..."

[[launcher.item]]
name = "深夜限定リマインダ"
filter-shell = "test $(date +%H) -ge 22"    # 22:00 以降のみ
action-type = "shell"
action-cmd  = "afplay /System/Library/Sounds/Glass.aiff"
```

`filter-title` はサブマイクロ秒(in-process グロブ、タイトルは
ボタン押下 / クリック時点でキャプチャ済)。`filter-shell` は
1 行あたり 5〜20ms(プロセス起動コスト)、100ms 強制
タイムアウト — 多用注意。

## インストール

```sh
brew install akira-toriyama/tap/wand
curl --create-dirs -o ~/.config/wand/config.toml \
  https://raw.githubusercontent.com/akira-toriyama/wand/main/config.toml
open "$(brew --prefix)/opt/wand/Wand.app"   # AX プロンプトが出る
```

System Settings → Privacy & Security → Accessibility で *wand* に
権限付与、その後 `wand` でデーモン起動。

ログイン時に自動起動するには:

```sh
brew services start wand
```

formula は `Wand.app`(LSUIElement = Dock アイコンなし)を同梱、
ログインキーチェーンに永続自己署名証明書を作成するので、
`brew upgrade wand` でも AX 権限が剥がれない。インストール中に
キーチェーンに届かない場合は ad-hoc 署名にフォールバックして
loud warning + 1 行リカバリ手順を表示する。詳細は
[packaging/homebrew/](packaging/homebrew/) を参照。

## 設定

wand は **config.toml 駆動**。設定 GUI は意図的に持たない。
上記 `curl` 行が `~/.config/wand/config.toml` にテンプレを
配置する。範囲外・未知の値は黙ってデフォルトに clamp される
ので、typo でデーモンが壊れることはない。明示的な検証は
`wand --validate` で。

ルール例:

```toml
[[gesture.rule]]
name = "close tab"
pattern = "DR"                        # 下 → 右
apps = ["*chrome*", "*safari*"]       # カーソル直下のウィンドウで判定
action-type = "key"
action-keys = "cmd+w"
```

方向アルファベットは `L U R D`(左 / 上 / 右 / 下)— **同方向の連打は
不可**。認識器が同じ方向の連続移動を1つにまとめるため(`LLLL…` は `L`、
`LL` ではない)、`DRR` / `LL` のように方向を繰り返すパターンは描けず、
`wand --validate` が起動時に loudly drop する。スクロール軸方向は
未対応。アクション種別は `key`(キーストローク)、`ax`(`close` /
`minimize` / `zoom` / `raise`)、`shell`(任意コマンド)、`url`(`https://`、`slack://`、`file://`
ほかインストール済みアプリの URL スキーム — `NSWorkspace.shared.open` 経由)。

`apps` は glob のリスト。正のエントリ(`*chrome*` / `com.apple.Safari`
/ `*` 全許可) + `!` プレフィクスの除外。**正のいずれかにマッチ**(または
正がそもそも無い) **かつ `!` のいずれにもマッチしない**ときに発動。
大文字小文字無視。例:

| `apps =` | 適用先 |
|---|---|
| `["*chrome*"]` | Chrome 系のみ |
| `[]` または `["*"]` | 全アプリ |
| `["!com.apple.dt.Xcode"]` | Xcode 以外の全アプリ |
| `["*", "!*.chrome.beta*"]` | Chrome ベータ以外の全アプリ |
| `["*chrome*", "*safari*"]` | Chrome または Safari |

`[gesture] max-segment-ms` で 1 セグメントの制限時間を設定 —
**曲がるたびにリセット**されるので、全体ではなく方向ごとの予算。
複数方向のジェスチャーは各区間にフル予算が与えられ、ひとつの方向で
止まったまま予算を超えたもの(通常の意図的な右ドラッグ)だけが破棄
される。`0`(既定)= 無制限。区間が予算を超えると軌跡が no-match
色に変わる。

`[gesture] cancel-reversals` は緊急脱出 — カーソルを **ぐしゃぐしゃ
と往復**させるとその場で進行中のジェスチャーを破棄する(タイムアウト
待ち不要、離しても何も発動しない)。180° の方向反転の回数で数え、既定
`2` なら通常のジェスチャーを誤判定せず意図的な往復だけを拾う。`0` = 無効。
`cancel-window-ms`(既定 `500`)は **速度** の条件 — 上記の反転がこの時間
窓内に収まったときだけキャンセルするので、素早い往復は効くがゆっくりした
往復は効かない。`0` = 速度不問。

`[gesture.overlay]` の中でヒントカードの退場アニメも設定する。各
カードは普段だと、現在の形から到達できなくなった瞬間にパッと消える
だけだが、効果を設定するとふわっと退場する。フックは 2 つ:

```toml
[gesture.overlay]
card-unmatch = "drop"        # ジェスチャー途中で到達不能になったカード
card-match   = "fireworks"   # ボタン離しで発動したカード
```

種類: `none`(既定)、`drop`、`rise`、`slide-left`、`slide-right`、
`explode`、`vibrate`、`fade`、`fireworks`、`confetti`、
`random`(カードが消えるたびに毎回別の効果を選ぶ)。
パーティクル系(`fireworks` / `confetti`)は `card-match` に置くと
一番映える。

overlay を off にしても効くカーソル位置のエフェクトは別軸:

```toml
[gesture.fire]
trail-end = "burst"          # 発火瞬間にカーソル位置でパーティクル放射
decal     = "ink-splatter"   # Splatoon 風の痕跡が残る
```

burst も decal も click-through な独立ウィンドウに描画されるので、
`[gesture.overlay].enabled = false` でも発火する。

エフェクト全体の倍率は `[gesture]` 直下の `intensity` 1 つで指定する
— overlay カードアニメと trail-end burst の両方をスケールする
(decal は独自の size / duration ノブを持つので非対象):

```toml
[gesture]
button = "right"
intensity = "wild"           # subtle | normal | bold | wild
```

## CLI

```sh
wand                    # agent として常駐(CGEventTap loop)
WAND_DEBUG=1 wand       # 詳細ログを /tmp/wand.log + stderr へ

wand --validate         # config.toml をパース、0 / 2 で exit
wand --doctor           # 健康診断: AX / config / daemon / tap
wand --test DR [app]    # ドライラン: そのパターンでどのルールが発動するか
wand --record           # 対話型レコーダ — 描くと貼れる [[gesture.rule]]
                          # スニペットが stdout に出る

wand --status           # ルール数・トリガー・最後のジェスチャー
wand --reload           # config.toml 再読込(保存時に自動でも走る)
wand --quit             # 動作中の daemon を終了
wand --help
```

daemon は **config.toml を保存時に自動リロード**する(`--reload` は手動
トリガー)。`--reload` / `--status` / `--quit` はクライアントコマンド —
daemon が居なければ exit 3 で拒否。
`--record` は逆に、daemon が **居れば** 拒否
(同じ CGEventTap を取り合うため)。

**再起動が必要な変更は 2 つだけ** — 残り全部はホットリロードで反映:
- `[gesture]`(button / modifiers) — `tapCreate` の event mask に
  焼き込まれている
- `[gesture.overlay].enabled = false → true` — 起動時に overlay 無効だと
  ウィンドウ自体作られないため、後で true にしても反映先がない

どちらも `wand --status` の `pending-restart:` 行に出る + リロード
時に `/tmp/wand.log` にも警告が出る。

## Contributing

コミットメッセージは **gitmoji + Conventional Commits**。CI が PR
ごとに [docs/commit-convention.md](docs/commit-convention.md) のフォーマット
に対して lint する。ローカル hook は
`git config core.hooksPath scripts/hooks` で有効化。

## ソースからビルド

```sh
swift build                       # CommandLineTools で OK
swift test                        # XCTest は Xcode が必要
.build/debug/wand --help        # 動作確認
```

AX 権限を永続化したローカル `Wand.app` を作るなら:

```sh
./setup-signing-cert.sh           # 1 回だけ — 安定した自己署名証明書を作成
./run.sh                          # ./package.sh + open Wand.app
./run.sh --dev                    # → Wand-dev.app (com.wand.wand.dev)
                                  #   Homebrew 版と並行検証する用
                                  #   (TCC 衝突を避けるための別バンドル id)
./stop.sh                         # 動いてる wand を全部殺す
```

## トラブルシュート

**`event-tap: tapCreate failed — is Accessibility granted?`** が
`/tmp/wand.log` に出る:macOS が Accessibility 権限を落とした
(または最初から付いてない)状態。
- **応急**: System Settings → Privacy & Security → Accessibility で
  `wand` のトグルを OFF/ON、または `+` でバイナリを追加 → 再起動
- **恒久**: `./setup-signing-cert.sh` を 1 回実行。ログインキーチェーンに
  安定した自己署名証明書を作る。以降 `swift build` / `package.sh` が
  毎回同じ identity で署名するので、TCC 権限が rebuild を跨いで残る

**`security find-identity -v -p codesigning` が 0 を返す**:
`-v` は trusted な codesigning identity だけフィルタするフラグで、
自己署名証明書は CA として trusted ではないため 0 でも正常。
`codesign --sign "<name>"` は CN マッチで自己署名証明書も使える。
`security find-certificate -c "wand Local Signing"` で実在確認可能。

**Chrome のページ本文上でジェスチャーが効かない**:Chrome の
renderer プロセス側で AX 親チェーンが切れる既知の挙動。wand は
`CGWindowListCopyWindowInfo` 経由のフォールバックで対応している
(ログに `AX: resolved … via cg-window → com.google.Chrome …` と
出る)。`via ax-walk` でも問題なし。どちらも出ない時は、メニューバー
/ Dock / デスクトップ上だった可能性が高い。

**`pattern = "DRR"` のような同方向連打のルールが発火しない**:仕様。
認識器が同方向の連続移動を1つにまとめるため、`DRR` は描けない。
`wand --validate` がロード時に明確な理由付きで drop する。
セグメントごとに異なる方向を組み合わせる(`DR` や `DRU` 等)。

## ライセンス

[MIT](LICENSE) © akira-toriyama
