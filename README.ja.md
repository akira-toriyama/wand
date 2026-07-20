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

## Cast — 描画トリガー

トリガーボタン(デフォルトは右ボタン)を押したまま描く。1 cast は
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

overlay の各パーツは sub-block で管理: トレイル線は
`[cast.overlay.trail]`、起点バッジは `[cast.overlay.badge]`、
ヒントカードの退場アニメは `[cast.overlay.cards]`。

ヒントカードには退場アニメーションも付けられる — drop / slide /
explode / vibrate / fireworks / confetti(花火・紙吹雪)。
ジェスチャー途中にカードが到達不能になった瞬間(`unmatch`)と、
ボタンを離してルールが発動した瞬間(`match`)それぞれに別の効果を
`[cast.overlay.cards]` で割り当てられる。既定はどちらも無し
(静かに消える)。overlay を off にしても効くカーソル位置のエフェクトは
独立 — burst は `[cast.fire.burst]`、痕跡は `[cast.fire.decal]`。

アクションは **カーソル直下のウィンドウ** を対象にする(キーボード
フォーカスを持つウィンドウではない): `ax` はそのウィンドウを直接
操作、`key` は raise してからキーを送る、`shell` はそのウィンドウの
識別子(bundle id, pid, title, frame)を環境変数で受け取る。

## Tome — 中クリックメニュー(opt-in)

wand は **中ボタンクリックで出るコンテキストメニュー** も第二の
トリガーとして持っている。既定で off。`[tome].enabled = true`
にすると、cast 用 event tap と別にもう一つの tap を立ち上げる。
tome は **non-activating panel** で描画される(フォーカスを奪わない):
下のアプリの**キーボードフォーカスを奪わず**に上に浮かぶので、エディタ
で typing を続けたままマウスで行を選べる。サブメニュー(`group =
["..."]`)は hover で隣に child panel として開く。外をクリック / Esc
で閉じる。Panel は **ボタン押下時にカーソル直下にあったウィンドウ** に
対して発動する — ジェスチャーと同じ不変条件。各 `[[tome.cursor.item]]`
が 1 行:

```toml
[tome]
enabled = true
button = "middle"                 # "middle" / "side1" / "side2" / "right"

[[tome.cursor.item]]
name = "新規タブ"
icon = "🌐"                        # emoji / SF:<name> / ファイルパス
apps = ["*chrome*", "*safari*"]
action-type = "key"
action-keys = "cmd+t"

[[tome.cursor.item]]
name = "名前順"
icon = "SF:textformat.abc"         # macOS SF Symbol
group = ["並び替え"]               # 「並び替え」サブメニュー配下
separator-before = true            # 行の上にセパレータ
action-type = "shell"
action-cmd = "echo name"
```

`icon` の書式: `"🌐"`(絵文字 / 1〜2 文字テキスト)、`"SF:globe"`
(SF Symbol — macOS 11+)、`"app:com.apple.Safari"`(その
bundle id で実行中アプリのアイコン)、`"~/icons/foo.png"` または
`"icons/foo.png"`(相対パスは `~/.config/wand/` 基準)、
`"/abs/path.png"`(絶対パス)。解決できない値はアイコンなしに
フォールバック(`/tmp/wand.log` にログ)。

行は **ドラッグ & ドロップで並び替え** できる(list layout のみ)。
行を掴んで別の行の上下に落とすとパネル内の並びが変わる。並び順は
**session-only** — config reload やデーモン再起動で破棄され、
`config.toml` の記述順に戻る。恒久的に変えたい場合は
`config.toml` の `[[tome.cursor.item]]` の並びを入れ替えること。

各行には `subtitle`(副題)、`header`(セパレータ見出し)、
SF Symbol アイコン向けの `tint` / `tint-colors` / `icon-anim`
も指定できる — 全項目は [`config.toml`](config.toml) 参照。
panel 全体の見た目は `[tome.row]`、`[tome.animation]`
(`open` / `close` ∈ `off | fade | pop`)、
`[tome.decoration]`(`border ∈ off | rainbow`)で調整可。
`[tome].layout` で panel を `list` / `toolbar` /
`labeled-toolbar` に切り替えられる。

アイテムは **動的サブメニュー** にもできる。`dynamic` にシェル
コマンドを指定し、`template-*` を埋めると、stdout の各行が `{line}`
置換された子アイテムになる:

```toml
[[tome.cursor.item]]
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
[[tome.cursor.item]]
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

### 選択テキストを使う shell アイテム(`$WAND_SELECTION`)

shell アクションには、中ボタン押下時にフォーカス要素で選択されて
いたテキストが `$WAND_SELECTION` 環境変数として渡される。翻訳 /
検索 / 他アプリへ渡す系のワークフローに使える:

```toml
[[tome.cursor.item]]
name = "Translate"
icon = "SF:globe"
action-type = "shell"
action-cmd = 'open "https://translate.google.com/?sl=auto&tl=en&text=$(printf %s "$WAND_SELECTION" | sed "s/ /%20/g")"'
```

wand の env var はすべて `WAND_` prefix 付きで、存在しない
context の変数は **unset**(空文字ではない)。だからコマンド側で
`[ -n "${WAND_SELECTION:-}" ] && …` のように有無で分岐できる。
`$WAND_SELECTION` は、何も選択していない・対象アプリが AX に
選択テキストを露出していない場合に unset になる。

shell コマンド内では必ず `"$WAND_SELECTION"` のようにクオート
する — 内容はユーザーがハイライトした任意の文字列(URL / コード /
shell メタ文字を含みうる)で、`WAND_TARGET_TITLE` と同じく
**untrusted**。

### 条件フィルタ(`filter-title` / `filter-shell`)

`apps` で「どのアプリの行か」を決め、**`filter-title`** で
ウィンドウタイトルを glob 絞り込み、**`filter-shell`** で
何でもありの shell 述語を評価する。`[[cast.cursor.rule]]` /
`[[tome.cursor.item]]` どちらでも使える:

```toml
[[tome.cursor.item]]
name = "Issue を PR にする"
icon = "SF:arrow.triangle.pull"
apps = ["*chrome*"]
filter-title = "*github.com*/issues/*"      # GitHub Issue のときだけ
action-type = "url"
action-url = "..."

[[tome.cursor.item]]
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
`wand config --validate` で。

> **`[failsafe]` ブロックは必須。** クリック / ドラッグ詰まりを
> 救済する安全策(ボタン保持タイムアウト、Esc 緊急解除)を
> 定義する。テンプレートに同梱されているので **削除しないこと** —
> `wand config --validate` と daemon 起動の両方が、無いと拒否する。
> 各ノブは [`config.toml`](config.toml) の `[failsafe]` 参照。

ルール例:

```toml
[[cast.cursor.rule]]
name = "close tab"
icon = "SF:xmark.square"              # 任意 — assist card で名前の左に表示
pattern = "DR"                        # 下 → 右
apps = ["*chrome*", "*safari*"]       # カーソル直下のウィンドウで判定
action-type = "key"
action-keys = "cmd+w"
```

`icon` は `[[tome.cursor.item]].icon` と同じ syntax — SF Symbol
(`"SF:globe"`)、絵文字 / テキスト glyph (`"🌐"`)、インストール
済みアプリのアイコン (`"app:com.apple.Safari"`)、ファイルパスの
いずれか。空 / 省略時はアイコンなし(矢印 + 名前のみ)。

方向アルファベットは `L U R D`(左 / 上 / 右 / 下)— **同方向の連打は
不可**。認識器が同じ方向の連続移動を1つにまとめるため(`LLLL…` は `L`、
`LL` ではない)、`DRR` / `LL` のように方向を繰り返すパターンは描けず、
`wand config --validate` が起動時に loudly drop する。スクロール軸方向は
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

cast / tome の**両方を特定アプリで無効化**したい場合は
`[exclude].apps` を使う(例:リモートデスクトップ系の中では wand を
止めたい等)。トリガー判定の最初で短絡するので、ルール / アイテム
の照合より先に効く。

trail 線のスタイル、起点バッジのサイズ、overlay 全体のブラー、
ジェスチャー終了後の余韻時間など overlay 系の詳細ノブは
`[cast.overlay.trail]` / `[cast.overlay.badge]` /
`[cast.overlay]` 配下にある — 全項目は注釈付きで
[`config.toml`](config.toml) に網羅。

`[cast.recognition].max-segment-ms` で 1 セグメントの制限時間を
設定 — **曲がるたびにリセット**されるので、全体ではなく方向ごとの予算。
複数方向のジェスチャーは各区間にフル予算が与えられ、ひとつの方向で
止まったまま予算を超えたもの(通常の意図的な右ドラッグ)だけが破棄
される。`0`(既定)= 無制限。区間が予算を超えると軌跡が no-match
色に変わる。

`[cast.recognition].cancel-reversals` は緊急脱出 — カーソルを
**ぐしゃぐしゃと往復**させるとその場で進行中のジェスチャーを破棄
する(タイムアウト待ち不要、離しても何も発動しない)。180° の方向
反転の回数で数え、既定 `2` なら通常のジェスチャーを誤判定せず
意図的な往復だけを拾う。`0` = 無効。
`cancel-window-ms`(既定 `500`)は **速度** の条件 — 上記の反転がこの時間
窓内に収まったときだけキャンセルするので、素早い往復は効くがゆっくりした
往復は効かない。`0` = 速度不問。

`[cast.overlay.cards]` でヒントカードの退場アニメを設定する。各
カードは普段だと、現在の形から到達できなくなった瞬間にパッと消える
だけだが、効果を設定するとふわっと退場する。フックは 2 つ:

```toml
[cast.overlay.cards]
cancel = "drop"         # ジェスチャー途中で到達不能になったカード
fire   = "fireworks"    # ボタン離しで発動したカード
```

種類: `off`(既定)、`drop`、`rise`、`slide-left`、`slide-right`、
`explode`、`vibrate`、`fade`、`fireworks`、`confetti`、
`random`(カードが消えるたびに毎回別の効果を選ぶ)。
パーティクル系(`fireworks` / `confetti`)は `fire` に置くと
一番映える。

overlay を off にしても効くカーソル位置のエフェクトは独立ウィンドウ:

```toml
[cast.fire.burst]
kind = "burst"          # off | burst

[cast.fire.decal]
kind = "ink-splatter"   # off | ink-splatter | paint-blob | scorch | star
duration-ms = 3000
size = 60
```

`[cast.overlay].enabled = false` でも発火する。

エフェクト全体の倍率は `[cast]` 直下の `intensity` 1 つで指定する
— overlay カードアニメと trail-end burst の両方をスケールする
(decal は独自の size / duration ノブを持つので非対象):

```toml
[cast]
button = "right"
intensity = "wild"           # subtle | normal | bold | wild
```

## CLI

yabai 式 `wand <domain> --<verb> [VALUE …]`。4 つの domain —
**daemon**(lifecycle)/ **cast**(ジェスチャエンジン)/ **tome**
(ランチャーメニュー)/ **config**(設定)。裸の `wand` は agent 起動。

```sh
wand                    # agent として常駐(CGEventTap loop)
WAND_DEBUG=1 wand       # 詳細ログを /tmp/wand.log + stderr へ

# daemon — lifecycle (daemon が必要; 居なければ exit 3)
wand daemon --reload    # config.toml 再読込(保存時に自動でも走る)
wand daemon --show      # ルール数・トリガー・最後のジェスチャー・カウンタ
wand daemon --quit      # 動作中の daemon を終了
wand daemon --resign    # インストール済 Wand.app を再署名 + 再起動
                        #   (`brew install` / upgrade 後に 1 回)

# cast — ジェスチャエンジン
wand cast --test DR [app]   # ドライラン: そのパターンでどのルールが発動するか
wand cast --record          # 対話型レコーダ → 貼れる [[cast.cursor.rule]]

# tome — ランチャーメニュー(外部トリガー)
wand tome --open --items <PATH> --at <X> <Y> [--selection <TEXT>] [--title <TEXT>]
                        #   tome を <X> <Y> に出す(Cocoa 座標、Y-up;
                        #   --at は負座標も可)。--selection → $WAND_SELECTION
                        #   (shell アクション用)、--title で $WAND_TARGET_TITLE 上書き。
wand tome --validate --items <PATH>   # standalone items ファイルを検証

# config — 設定
wand config --validate  # config.toml を schema 検証、exit 0 (valid) / 1 (schema 違反) / 2 (parse 不能)
wand config --doctor    # 健康診断: AX / config / daemon / tap
wand config --emit-schema   # config.toml JSON Schema(Draft-07)を出力

wand --help, -h
```

各 domain は verb を **1 つだけ**取る。verb の併用(例:
`wand daemon --reload --quit`)や domain 外のフラグ(例:`tome` 無しの
`--items`)は exit `2`。silent fallback はしない — 未知フラグには
`did you mean …?` ヒントが出る。

daemon は **config.toml を保存時に自動リロード**する(`daemon --reload` は
手動トリガー)。`daemon --reload` / `daemon --show` / `daemon --quit` /
`tome --open` は daemon が必要(居なければ exit 3 で拒否)。
`cast --record` は逆に、daemon が **居れば** 拒否(同じ CGEventTap を
取り合うため)。

### 移行(フラット flag → yabai 式 domain)

deprecation シムは **無い** — 旧フラット flag は exit 2。対応表:

| 旧 | 新 |
|---|---|
| `wand --reload` / `--status` / `--quit` / `--resign` | `wand daemon --reload` / `--show` / `--quit` / `--resign` |
| `wand --test P [app]` / `--record` | `wand cast --test P [app]` / `--record` |
| `wand --show-menu --items … --at …` | `wand tome --open --items … --at …` |
| `wand --validate --items P` | `wand tome --validate --items P` |
| `wand --validate` / `--doctor` / `--emit-schema` | `wand config --validate` / `--doctor` / `--emit-schema` |

**再起動が必要な変更は 2 つだけ** — 残り全部はホットリロードで反映:
- `[cast]`(button / modifiers) — `tapCreate` の event mask に
  焼き込まれている
- `[cast.overlay].enabled = false → true` — 起動時に overlay 無効だと
  ウィンドウ自体作られないため、後で true にしても反映先がない

どちらも `wand daemon --show` の `pending-restart:` 行に出る + リロード
時に `/tmp/wand.log` にも警告が出る。

## Contributing

コミットメッセージは **gitmoji 駆動**。CI が PR
ごとに [CONTRIBUTING.md](https://github.com/akira-toriyama/.github/blob/main/CONTRIBUTING.md) のフォーマット
に対して lint する。ローカル hook は clone ごとに
`glyph hook install` で導入。

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

**Chrome のページ本文上で cast が効かない**:Chrome の
renderer プロセス側で AX 親チェーンが切れる既知の挙動。wand は
`CGWindowListCopyWindowInfo` 経由のフォールバックで対応している
(ログに `AX: resolved … via cg-window → com.google.Chrome …` と
出る)。`via ax-walk` でも問題なし。どちらも出ない時は、メニューバー
/ Dock / デスクトップ上だった可能性が高い。

**`pattern = "DRR"` のような同方向連打のルールが発火しない**:仕様。
認識器が同方向の連続移動を1つにまとめるため、`DRR` は描けない。
`wand config --validate` がロード時に明確な理由付きで drop する。
セグメントごとに異なる方向を組み合わせる(`DR` や `DRU` 等)。

## ライセンス

[MIT](LICENSE) © akira-toriyama
