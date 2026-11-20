#!/bin/zsh
# WaveGenFS.app をビルドする。  ./build_app.sh            … ビルドして起動
#                               ./build_app.sh --install  … /Applications にインストールして起動
set -e
cd "$(dirname "$0")"

if [[ -z "$DEVELOPER_DIR" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

APP=WaveGenFS.app
swift build -c release
BIN="$(swift build -c release --show-bin-path)/WaveGenFS"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WaveGenFS"
cp Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" && \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
xattr -cr "$APP"   # 拡張属性が残っていると署名できない
codesign --force --deep --sign - "$APP"

# 起動中なら正常終了させる (pkill だと設定が保存されない)
osascript -e 'tell application "WaveGenFS" to quit' 2>/dev/null || true
for i in {1..20}; do pgrep -x WaveGenFS >/dev/null || break; sleep 0.25; done
sleep 0.5

if [[ "$1" == "--install" ]]; then
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  open "/Applications/$APP"
elif [[ "$1" != "--no-open" ]]; then
  open "$APP"
fi
