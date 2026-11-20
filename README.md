# WaveGenFS (Mac 版)

Mac 用の低周波信号発生器 (Swift / AppKit)。Windows 版 [WaveGenFS-Win](https://github.com/kazushinjo/WaveGenFS-Win) の移植で、全画面の波形表示に対応。

## 入手
次のどれかで入れる。Apple シリコン / Intel 両対応、macOS 13 以降。

| ファイル | 入れ方 |
|---|---|
| [WaveGenFS-mac.pkg](WaveGenFS-mac.pkg) (インストーラー) | 開いて画面の指示どおり進めると「アプリケーション」に入る (使用許諾 GPL v3 の同意あり) |
| [WaveGenFS-mac.dmg](WaveGenFS-mac.dmg) | 開いて `WaveGenFS.app` を「Applications」へドラッグ |
| [Releases](https://github.com/kazushinjo/WaveGenFS-mac/releases) の zip | 展開して `WaveGenFS.app` を「アプリケーション」へ |

Apple の公証を受けていないため、初回は「開発元を確認できません」と出る。インストーラーは Finder で右クリック →「開く」、アプリも同じく右クリック →「開く」で起動するか、「システム設定 → プライバシーとセキュリティ」で「このまま開く」を選ぶ。

## 主な機能 (Windows 版と同じ)
- 波形合成 (Mac 版は最大 5 系統、表示数は「Wave数」で 1〜5 を選ぶ): サイン / 矩形 / 三角 / ノコギリ / パルス / パルス(+-) / ホワイト・ピンク・M系列ノイズ
- 周波数 (Hz / 周期サンプル数), 振幅 (dB / 値 / %, 極性反転), オフセット, 位相, 出力 ch
- 詳細設定: 遅延, デューティ, 帯域制限 (PolyBLEP), ゲート, 周波数スイープ, AM/FM 変調
- クリップ防止 (合計ピークが 100% を超える振幅は設定不可)
- 出力減衰 1/N (ON/OFF), Volume最大
- FFT用に最適化 (Fs/N の整数倍), Wave2〜5 を Wave1 の倍数に設定 (周波数欄の右クリック)
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
| 波形の数 | 最大 5 系統 (Wave1〜5)。「Wave数」(表示ch の左) で 1〜5 個を選ぶ。隠した Wave は設定を残したまま出力しない (WAV・設定ファイルにも入れない)。設定ファイルを開いたとき、使っている Wave が隠れていれば表示数を増やす。設定ファイルは Windows 版と同じ 8 系統の形式で保存し、Wave6〜8 は OFF。Windows 版のファイルで Wave6〜8 を使っているものは、読み込み時に OFF にしてお知らせを出す |
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
./build_app.sh --release  # 配布用 zip (dist/) と WaveGenFS-mac.pkg / .dmg を作る
```
macOS 13 以降。Xcode (またはコマンドラインツール) の Swift が必要。

## 免責事項
- 本ソフトウェアは無保証です。作者は、本ソフトウェアの使用・使用不能、またはその結果によって生じたいかなる損害 (機器の故障・データの消失・聴覚の障害などを含む) についても責任を負いません。すべて使用者の責任でお使いください。
- 本ソフトウェアは試験用の信号を出力します。大きな音量・高い周波数・直流成分 (オフセット) を含む信号は、スピーカー・ヘッドホン・アンプなどの機器や耳を傷めることがあります。再生前に出力機器の音量を下げ、「出力 1/N」で減衰させるなどして、小さな音量から確かめてください。
- 出力する信号の周波数・振幅・波形の正確さは保証しません。測定や校正に使う場合は、別の測定器で確かめてください。
- 本ソフトウェアの仕様は予告なく変更することがあります。

## ライセンス
GPL v3 (GNU General Public License version 3)。本文は [LICENSE](LICENSE)。
Copyright (C) 2026 Kazu Shinjo (JA6FUF/JH1XHX)

このプログラムはフリーソフトウェアです。GPL v3 (またはそれ以降の版) の条件で再配布・改変できます。無保証です。
