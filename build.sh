#!/bin/bash
# 乾淨建置 dist/靜醒.app（Apple Silicon、release、ad-hoc 簽章）。
# 用法：./build.sh            建置
#       ./build.sh --test     先跑測試再建置
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="靜醒"
EXEC="JingXing"
# 可用 DIST=其他目錄 ./build.sh 輸出到別處（例如 dist 內的 App 正在執行時）。
DIST="${DIST:-dist}"
APP="$DIST/$APP_NAME.app"

if [[ "${1:-}" == "--test" ]]; then
  echo "▸ 執行測試（以 caffeinate 避免 Mac 途中睡眠造成假失敗；不更改系統設定）"
  caffeinate -i -s swift test
fi

echo "▸ 清除舊的建置產物"
rm -rf .build/release .build/arm64-apple-macosx/release "$APP" "$DIST/AppIcon.iconset"

echo "▸ swift build（release, arm64）"
swift build -c release --arch arm64 --product "$EXEC"
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$EXEC"

echo "▸ 組裝 $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 語系資源：繁體中文「靜醒」、英文「Awaken」；App 依 macOS（含個別 App）語言設定選擇。
for LPROJ in zh-Hant.lproj en.lproj; do
  mkdir -p "$APP/Contents/Resources/$LPROJ"
  cp "Resources/$LPROJ/InfoPlist.strings" "$APP/Contents/Resources/$LPROJ/InfoPlist.strings"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ 產生圖示"
swift Scripts/make-icon.swift "$DIST/AppIcon.iconset" >/dev/null
iconutil -c icns "$DIST/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$DIST/AppIcon.iconset"

echo "▸ ad-hoc 簽章"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "▸ 檢查"
plutil -lint "$APP/Contents/Info.plist" "$APP/Contents/Resources/"*.lproj/InfoPlist.strings
lipo -archs "$APP/Contents/MacOS/$EXEC"
echo "完成：$APP"
