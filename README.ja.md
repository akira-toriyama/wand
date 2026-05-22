# stroke

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![swift](https://img.shields.io/badge/Swift-6.0-orange)
![license](https://img.shields.io/badge/license-MIT-blue)

[English](README.md) · **日本語**

macOS 用のグローバルマウスジェスチャーデーモン。マウスのボタンを
押したままカーソルで短い形 — 下、そして右 — を描くと、stroke が
アクションを実行する: タブを閉じる、開き直す、ウィンドウを最小化、
シェルコマンドを走らせる。アクションは **描き始めた時にカーソルが
乗っていたウィンドウ** に対して実行される。

## ジェスチャー

トリガーボタン(デフォルトは右ボタン)を押したまま描く。1 ストロークは
方向の並び:

```
L = 左    U = 上    R = 右    D = 下
```

`DR` は 下→右、`URD` は 上→右→下。ボタンを離すと stroke が形を
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

描いている間、カーソルに半透明の軌跡が追従して形が見える。ボタンを
離した瞬間に消える。軌跡は **今の形がルールにマッチしているかで色が
変わる** — カーソル下のウィンドウで有効なジェスチャーなら 1 色、
どのルールにも当たらない形になると別の色。カーソル横に、今の形を
**矢印**(`↓→`)で出し、さらに **ジェスチャー・アシスト** — 今の形から
到達できるルールを、**残りの描き分だけ**表示する(今すぐ発動するものはマッチ色で表示):

```
↓
  ←   タブを閉じる
  →↑  ウィンドウを閉じる
```

`↓` まで描けば、どちらに行けて何を足せばいいか分かる。軌跡は今の形が
ルールを発動する時は match 色、そうでなければ no-match 色。色・太さ・
on/off は `config.toml` の `[overlay]` で設定。

アクションは **カーソル直下のウィンドウ** を対象にする(キーボード
フォーカスを持つウィンドウではない): `ax` はそのウィンドウを直接
操作、`key` は raise してからキーを送る、`shell` はそのウィンドウの
識別子(bundle id, pid, title, frame)を環境変数で受け取る。

## インストール

```sh
brew install akira-toriyama/tap/stroke
curl --create-dirs -o ~/.config/stroke/config.toml \
  https://raw.githubusercontent.com/akira-toriyama/stroke/main/config.toml
open "$(brew --prefix)/opt/stroke/Stroke.app"   # AX プロンプトが出る
```

System Settings → Privacy & Security → Accessibility で *stroke* に
権限付与、その後 `stroke` でデーモン起動。

ログイン時に自動起動するには:

```sh
brew services start stroke
```

formula は `Stroke.app`(LSUIElement = Dock アイコンなし)を同梱、
ログインキーチェーンに永続自己署名証明書を作成するので、
`brew upgrade stroke` でも AX 権限が剥がれない。インストール中に
キーチェーンに届かない場合は ad-hoc 署名にフォールバックして
loud warning + 1 行リカバリ手順を表示する。詳細は
[packaging/homebrew/](packaging/homebrew/) を参照。

## 設定

stroke は **config.toml 駆動**。設定 GUI は意図的に持たない。
上記 `curl` 行が `~/.config/stroke/config.toml` にテンプレを
配置する。範囲外・未知の値は黙ってデフォルトに clamp される
ので、typo でデーモンが壊れることはない。明示的な検証は
`stroke --validate` で。

ルール例:

```toml
[[rules]]
name = "close tab"
pattern = "DR"                        # 下 → 右
apps = ["*chrome*", "*safari*"]       # カーソル直下のウィンドウで判定
action-type = "key"
action-keys = "cmd+w"
```

方向アルファベットは `L U R D`(左 / 上 / 右 / 下)。
スクロール軸方向は未対応。アプリフィルタは `*` / `?` グロブと
`!` による除外をサポート。アクション種別は `key`(キーストローク)、
`ax`(`close` / `minimize` / `zoom` / `raise`)、`shell`(任意コマンド)。

`[recognition] max-stroke-ms` で 1 セグメントの制限時間を設定 —
**曲がるたびにリセット**されるので、全体ではなく方向ごとの予算。
複数方向のジェスチャーは各区間にフル予算が与えられ、ひとつの方向で
止まったまま予算を超えたもの(通常の意図的な右ドラッグ)だけが破棄
される。`0`(既定)= 無制限。区間が予算を超えると軌跡が no-match
色に変わる。

`[recognition] cancel-reversals` は緊急脱出 — カーソルを **ぐしゃぐしゃ
と往復**させるとその場で進行中のジェスチャーを破棄する(タイムアウト
待ち不要、離しても何も発動しない)。180° の方向反転の回数で数え、既定
`2` なら通常のジェスチャーを誤判定せず意図的な往復だけを拾う。`0` = 無効。
`cancel-window-ms`(既定 `500`)は **速度** の条件 — 上記の反転がこの時間
窓内に収まったときだけキャンセルするので、素早い往復は効くがゆっくりした
往復は効かない。`0` = 速度不問。

## CLI

```sh
stroke                    # agent として常駐(CGEventTap loop)
stroke --debug            # 詳細ログを /tmp/stroke.log + stderr へ

stroke --validate         # config.toml をパース、0 / 2 で exit
stroke --doctor           # 健康診断: AX / config / daemon / tap
stroke --test DR [app]    # ドライラン: そのパターンでどのルールが発動するか
stroke --record           # 対話型レコーダ — 描くと貼れる [[rules]]
                          # スニペットが stdout に出る

stroke --status           # ルール数・トリガー・最後のジェスチャー
stroke --reload           # config.toml 再読込(保存時に自動でも走る)
stroke --quit             # 動作中の daemon を終了
stroke --help
```

daemon は **config.toml を保存時に自動リロード**する(`--reload` は手動
トリガー)。`--reload` / `--status` / `--quit` はクライアントコマンド —
daemon が居なければ exit 3 で拒否。
`--record` は逆に、daemon が **居れば** 拒否
(同じ CGEventTap を取り合うため)。

## アーキテクチャ

Hexagonal(Ports & Adapters)、3 層構成:

```
StrokeApp           @main / CLI / Controller(配線層)
    │
StrokeCore          純粋ロジック:認識、マッチング、設定。
    │               AppKit / AX / CGEvent 非依存。単体テスト可能。
    │
    ├── StrokeAdapterMacOS    CGEventTap + AX + アクション実行
    └── StrokeAdapterTest     テスト用合成イベントソース
```

詳細: [docs/architecture.md](docs/architecture.md)。

## Contributing

コミットメッセージは **gitmoji + Conventional Commits**。CI が PR
ごとに [docs/commit-convention.md](docs/commit-convention.md) のフォーマット
に対して lint する。ローカル hook は
`git config core.hooksPath scripts/hooks` で有効化。

## ソースからビルド

```sh
swift build                       # CommandLineTools で OK
swift test                        # XCTest は Xcode が必要
.build/debug/stroke --help        # 動作確認
```

AX 権限を永続化したローカル `Stroke.app` を作るなら:

```sh
./setup-signing-cert.sh           # 1 回だけ — 安定した自己署名証明書を作成
./run.sh                          # ./package.sh + open Stroke.app
./run.sh --dev                    # → Stroke-dev.app (com.stroke.stroke.dev)
                                  #   Homebrew 版と並行検証する用
                                  #   (TCC 衝突を避けるための別バンドル id)
./stop.sh                         # 動いてる stroke を全部殺す
```

## ライセンス

[MIT](LICENSE) © akira-toriyama
