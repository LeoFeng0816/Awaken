#!/bin/bash
# 建立拖曳安裝 DMG：靜醒.app、指向 /Applications 的捷徑、背景中的拖曳指示與安裝說明檔。
#
# 用法：Scripts/build-dmg.sh [path/to/靜醒.app]
#   沒有參數時，先在獨立的暫存目錄乾淨建置 App（不碰 dist/ 中可能正在執行的 App）。
#   DMG_OUTPUT_DIR=<目錄>  輸出位置（預設 dist/dmg）；已有同名檔案時拒絕覆寫。
#
# 全程不需要管理員權限、不使用 Finder AppleScript、不安裝任何東西；
# 只在暫存目錄掛載自己建立的映像檔，結束（含失敗）時一定卸載並清除暫存檔。
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT_ROOT="$PWD"
APP_NAME="靜醒.app"
VOLUME_NAME="Awaken"
GUIDE_FILE="Drag to Applications · 拖曳到應用程式.txt"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/awaken-dmg.XXXXXXXX")"
MOUNT_POINT="$WORK_DIR/mnt"
cleanup() {
  if [[ -d "$MOUNT_POINT" ]] && mount | grep -qF " on $MOUNT_POINT "; then
    hdiutil detach -quiet "$MOUNT_POINT" || hdiutil detach -quiet -force "$MOUNT_POINT" || true
  fi
  if [[ -d "$MOUNT_POINT" ]] && mount | grep -qF " on $MOUNT_POINT "; then
    echo "Could not detach $MOUNT_POINT; preserving temporary files for manual cleanup." >&2
  else
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [path/to/$APP_NAME]" >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  APP_PATH="$1"
else
  DIST="$WORK_DIR/build" ./build.sh
  APP_PATH="$WORK_DIR/build/$APP_NAME"
fi
[[ -d "$APP_PATH/Contents" ]] || { echo "App not found: $APP_PATH" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid app version: $VERSION" >&2; exit 1; }
EXEC="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP_PATH/Contents/Info.plist")"
ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/$EXEC")"
[[ "$ARCHS" == "arm64" ]] || { echo "Expected a native arm64 app, got: $ARCHS" >&2; exit 1; }
codesign --verify --strict --deep "$APP_PATH"

OUTPUT_DIR="${DMG_OUTPUT_DIR:-$PROJECT_ROOT/dist/dmg}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
OUTPUT="$OUTPUT_DIR/Awaken-v${VERSION}-macOS-arm64.dmg"
if [[ -e "$OUTPUT" ]]; then
  echo "Refusing to overwrite existing image: $OUTPUT" >&2
  exit 1
fi

echo "▸ 準備 DMG 內容"
STAGE="$WORK_DIR/contents"
mkdir -p "$STAGE/.background"
ditto "$APP_PATH" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"
swift Scripts/dmg-layout.swift background "$WORK_DIR/art" >/dev/null
tiffutil -cathidpicheck "$WORK_DIR/art/background.png" "$WORK_DIR/art/background@2x.png" \
  -out "$STAGE/.background/background.tiff" >/dev/null
cp "$APP_PATH/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
cat > "$STAGE/$GUIDE_FILE" <<TEXT
Install Awaken ${VERSION} / 安裝靜醒 ${VERSION}

1. Drag 靜醒 (Awaken) onto the Applications folder in this window.
2. Open Awaken from your Applications folder (not from this disk image).
3. Eject the "${VOLUME_NAME}" disk image.

This build is ad-hoc signed. It is NOT signed with an Apple Developer ID and
NOT notarized by Apple, so macOS may block the first launch. Only if you trust
the source and have checked the download (for example its SHA-256 checksum on
the release page), open System Settings > Privacy & Security, scroll to
Security, and click "Open Anyway" for Awaken. Apple's guide:
https://support.apple.com/en-us/102445

Requirements: Apple Silicon (arm64) Mac, macOS 14 or later.
Details and limitations: https://github.com/LeoFeng0816/Awaken

----

1. 把這個視窗中的「靜醒」拖曳到「Applications（應用程式）」資料夾。
2. 從「應用程式」資料夾開啟靜醒（不要直接從磁碟映像檔開啟）。
3. 退出「${VOLUME_NAME}」磁碟映像檔。

此版本為 ad-hoc 簽章，沒有 Apple Developer ID 簽章，也未經 Apple 公證，
macOS 可能會阻擋首次開啟。只有在你信任來源並確認下載檔案（例如核對發布頁面上的
SHA-256）後，才到「系統設定 › 隱私權與安全性」，捲動到「安全性」，對靜醒按
「仍要打開」。Apple 說明：https://support.apple.com/zh-tw/102445

系統需求：Apple Silicon（arm64）Mac、macOS 14 或以上。
完整說明與限制：https://github.com/LeoFeng0816/Awaken
TEXT

echo "▸ 建立可寫入映像檔並寫入 Finder 版面"
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -quiet -fs HFS+ -volname "$VOLUME_NAME" -size "${SIZE_MB}m" \
  -srcfolder "$STAGE" -format UDRW "$WORK_DIR/rw.dmg"
mkdir -p "$MOUNT_POINT"
hdiutil attach -quiet -readwrite -nobrowse -noautoopen -noverify \
  -mountpoint "$MOUNT_POINT" "$WORK_DIR/rw.dmg"
swift Scripts/dmg-layout.swift layout "$MOUNT_POINT" "$APP_NAME" "$VOLUME_NAME"
SetFile -a C "$MOUNT_POINT"                        # 使用 .VolumeIcon.icns 作為卷宗圖示
SetFile -a V "$MOUNT_POINT/.background" "$MOUNT_POINT/.VolumeIcon.icns"
rm -rf "$MOUNT_POINT/.fseventsd" "$MOUNT_POINT/.Trashes"
sync
hdiutil detach -quiet "$MOUNT_POINT"

echo "▸ 壓縮為唯讀 UDZO 並 ad-hoc 簽章"
hdiutil convert -quiet "$WORK_DIR/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$WORK_DIR/Awaken.dmg"
codesign --force --sign - --timestamp=none "$WORK_DIR/Awaken.dmg"
codesign --verify --strict "$WORK_DIR/Awaken.dmg"
hdiutil verify -quiet "$WORK_DIR/Awaken.dmg"
mv "$WORK_DIR/Awaken.dmg" "$OUTPUT"
(cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$OUTPUT")" | tee "$(basename "$OUTPUT").sha256")
echo "Created: $OUTPUT"
