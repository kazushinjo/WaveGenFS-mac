# WaveGenFS (Mac 版)

Mac 用の音声テスト信号発生器 (Swift / AppKit)。Windows 版 [WaveGenFS](https://github.com/kazushinjo/WaveGenFS) の移植で、全画面の波形表示に対応。

## 主な機能 (Windows 版と同じ)
- 波形合成 (Mac 版は Wave1・Wave2 の 2 系統): サイン / 矩形 / 三角 / ノコギリ / パルス / パルス(+-) / ホワイト・ピンク・M系列ノイズ
- 周波数 (Hz / 周期サンプル数), 振幅 (dB / 値 / %, 極性反転), オフセット, 位相, 出力 ch
- 詳細設定: 遅延, デューティ, 帯域制限 (PolyBLEP), ゲート, 周波数スイープ, AM/FM 変調
- クリップ防止 (合計ピークが 100% を超える振幅は設定不可)
- 出力減衰 1/N (ON/OFF), Volume最大
- FFT用に最適化 (Fs/N の整数倍), Wave2 を Wave1 の倍数に設定 (周波数欄の右クリック)
- WAV 保存 (16/24bit, 32bit float), 設定ファイル (*.wgfs) 保存/読込 — Windows 版と同じ形式で相互に読める
- 全画面, 波形のみ表示, スクロールで時間軸 / ⌘+スクロールで振幅軸
- L/R分離表示 (Mac 版で追加): 表示ch の右のボタンで L を上段・R を下段に分けて表示 (Stereo・Lch + Rch のとき)

## Mac 版での違い
| 項目 | Mac 版 |
|---|---|
| 再生 | Core Audio (32bit float)。再生中は出力デバイスのサンプリング周波数を Fs に合わせ、停止で元に戻す。デバイスが対応しない Fs は Core Audio が変換し、波形表示の右上に「デバイス ○○Hz に変換」と出る |
| bit | WAV 保存のビット数 (再生には関係しない) |
| Volume最大 | 再生中だけ出力デバイスの音量を最大にし、停止で元に戻す |
| 遅延 | デバイスのバッファサイズの目安 (対応範囲に丸められる) |
| 波形の数 | Wave1・Wave2 の 2 系統。設定ファイルは Windows 版と同じ 8 系統の形式で保存し、Wave3〜8 は OFF。Windows 版のファイルで Wave3〜8 を使っているものは、読み込み時に OFF にしてお知らせを出す |
| 設定の保存先 | `~/Library/Application Support/WaveGenFS/WaveGenFS.json` |

## キー操作
| 操作 | キー |
|---|---|
| 再生 / 停止 | F5, ⌘R |
| 全画面 | F11, ⌃⌘F |
| 波形のみ | F12, ⌘L |
| L/R分離表示 | ⌘D |
| 戻る (全画面・波形のみ解除) | Esc |
| 設定を開く / 保存 | ⌘O / ⌘S |
| WAV 保存 | ⌘E |

F キーは「システム設定 → キーボード → F1、F2 などのキーを標準のファンクションキーとして使用」が OFF のときは fn と一緒に押す。

## アイコン
`swift Scripts/make_icon.swift` で `Resources/AppIcon.icns` を作り直せる (サイン波・スコープ風)。

## ビルド
```
./build_app.sh            # ビルドして起動
./build_app.sh --install  # /Applications にインストールして起動
```
macOS 13 以降。Xcode (またはコマンドラインツール) の Swift が必要。
