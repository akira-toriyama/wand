# stroke

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![swift](https://img.shields.io/badge/Swift-6.0-orange)
![license](https://img.shields.io/badge/license-MIT-blue)
![status](https://img.shields.io/badge/status-M4%20ipc%20%2B%20recorder-orange)

[English](README.md) · **日本語**

macOS 用のグローバルマウスジェスチャーデーモン。マウスで形を描くと、
**カーソルが乗っていたウィンドウ** に対してアクションが実行される —
たまたまフォーカスを持っていたウィンドウではなく。

[MacGesture](https://github.com/MacGesture/MacGesture) や
[xGestures](https://www.briankendall.net/xGestures/) の思想的後継。
これらが解決できていない一点
— **カーソル基準のターゲット解決** — を中心に据えて設計している。
詳細は [なぜ stroke を作るか](#なぜ-stroke-を作るか) を参照。

## ステータス

**M4 — ライブリロード、対話型レコーダ、IPC**。
`~/.config/stroke/config.toml` を編集 → `stroke --reload` で
イベントタップや AX 権限を失わずにルールが差し替わる。
`stroke --record` は対話型レコーダ
(`pattern=DR  samples=421  max|dx|=180 max|dy|=92  target=...`)
で、ルールに落とし込む前にジェスチャーを試打ちできる。
`stroke --quit` でデーモンを綺麗に終了。クライアント系コマンドは
デーモンが居なければ exit 3 で拒否、`--record` は逆にデーモンが
居れば拒否(同じタップを取り合わないため)。

| マイルストーン | 状態 |
|---|---|
| M1 — リポジトリ scaffold、`swift build` グリーン、config パース、認識アルゴリズム | ✅ |
| M2 — CGEventTap で実イベント捕捉、`key` / `shell` アクション動作 | ✅ |
| M3 — AX による cursor-anchored ターゲット解決(#115 解決)、`ax` アクション動作 | ✅ |
| M4 — `--reload`、`--record`、`--quit` | ✅ |
| M5 — Homebrew tap、署名済みバンドル | ⏳ |

## なぜ stroke を作るか

[MacGesture issue #115](https://github.com/MacGesture/MacGesture/issues/115)
が問題を端的に示している。マルチディスプレイ環境で MacGesture は壊れる:
ディスプレイ 2 の Chrome を指したままジェスチャーを描いても、ディスプレイ 1 でフォーカスを持っているアプリにキーストロークが飛ぶ。古い xGestures も同じ問題を抱えている。

stroke は **ボタン押下時点でカーソル直下のウィンドウを
`AXUIElementCopyElementAtPosition` で解決し**、以降すべてのアクションを
**そのウィンドウに対して** 実行する:

- `ax` アクションはフォーカス移動なしで対象ウィンドウを直接操作
- `key` アクションは対象ウィンドウを raise してからキーを送る
- `shell` アクションは対象の識別子を環境変数で渡す

カーソルが ground truth。

## 設定

stroke は **config.toml 駆動**。設定 GUI は意図的に持たない。
[`config.toml`](config.toml) を `~/.config/stroke/config.toml` に配置:

```sh
curl --create-dirs -o ~/.config/stroke/config.toml \
  https://raw.githubusercontent.com/akira-toriyama/stroke/main/config.toml
```

範囲外・未知の値は黙ってデフォルトに clamp されるので、typo でデーモンが壊れることはない。明示的な検証は `stroke --validate` で。

ルール例:

```toml
[[rules]]
name = "close tab"
pattern = "DR"                        # 下 → 右
apps = ["*chrome*", "*safari*"]       # ← カーソル直下のウィンドウで判定
action-type = "key"
action-keys = "cmd+w"
```

方向アルファベットは MacGesture 互換の `L U R D`(左 / 上 / 右 / 下)。
スクロール軸方向(MacGesture の `u` / `d`)は M2 以降。
アプリフィルタは `*` / `?` グロブと `!` による除外をサポート。

## CLI

```sh
stroke                    # agent として常駐(CGEventTap loop)
stroke --debug            # 詳細ログを /tmp/stroke.log + stderr へ

stroke --validate         # config.toml をパース、0 / 2 で exit
stroke --record           # 対話型レコーダ — 描くと pattern + サンプル数
                          # + 変位幅が stdout に出る

stroke --reload           # 動作中の daemon に config.toml の再読込を依頼
stroke --quit             # 動作中の daemon を終了
stroke --help
```

`--reload` / `--quit` はクライアントコマンド —
daemon が居なければ exit 3 で拒否。
`--record` は逆に、daemon が **居れば** 拒否
(同じ CGEventTap を取り合うため)。

## アーキテクチャ

Hexagonal(Ports & Adapters)、3 層構成 — [facet](https://github.com/akira-toriyama/facet) を踏襲:

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

## ライセンス

[MIT](LICENSE) © akira-toriyama
