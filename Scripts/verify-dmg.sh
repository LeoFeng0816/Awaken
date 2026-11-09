#!/bin/bash
# 唯讀驗證 DMG：在暫存目錄以唯讀、不顯示於 Finder 的方式掛載，檢查後一定卸載。
# 用法：Scripts/verify-dmg.sh path/to/Awaken-vX.Y.Z-macOS-arm64.dmg [預期版本]
# 不執行 App、不複製到 /Applications、不需要管理員權限。
set -euo pipefail
cd "$(dirname "$0")/.."
DMG="${1:?Usage: $0 <dmg> [expected-version]}"
EXPECTED_VERSION="${2:-}"
APP_NAME="靜醒.app"
GUIDE_FILE="Drag to Applications · 拖曳到應用程式.txt"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/awaken-verify.XXXXXXXX")"
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

ok() { printf '  ✔ %s\n' "$1"; }
die() { printf '  ✘ %s\n' "$1" >&2; exit 1; }

echo "▸ 映像檔"
hdiutil verify -quiet "$DMG" || die "hdiutil verify"
ok "hdiutil verify"
FORMAT="$(hdiutil imageinfo "$DMG" 2>/dev/null | awk -F': ' '/^Format:/ {print $2}' | head -n 1)"
[[ "$FORMAT" == "UDZO" ]] || die "format: $FORMAT"
ok "format UDZO (read-only, compressed)"
codesign --verify --strict "$DMG" || die "DMG signature invalid"
ok "DMG signature valid"
DMG_SIG="$(codesign -dv "$DMG" 2>&1 || true)"
[[ "$DMG_SIG" == *"Signature=adhoc"* ]] || die "DMG is not ad-hoc signed"
ok "DMG signature is ad-hoc (not Developer ID)"

echo "▸ 唯讀掛載（-nobrowse，不出現在 Finder）"
mkdir -p "$MOUNT_POINT"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_POINT" "$DMG"
ok "mounted at $MOUNT_POINT"

APP="$MOUNT_POINT/$APP_NAME"
[[ -d "$APP/Contents" ]] && ok "$APP_NAME present" || die "$APP_NAME missing"
[[ -L "$MOUNT_POINT/Applications" && "$(readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] \
  && ok "Applications -> /Applications symlink" || die "Applications symlink missing or wrong"
[[ -f "$MOUNT_POINT/$GUIDE_FILE" ]] && grep -q "Open Anyway" "$MOUNT_POINT/$GUIDE_FILE" \
  && grep -q "仍要打開" "$MOUNT_POINT/$GUIDE_FILE" && ok "install guide file (EN/中文)" || die "guide file"
[[ -f "$MOUNT_POINT/.background/background.tiff" ]] && ok "background image" || die "background missing"
[[ "$(tiffutil -info "$MOUNT_POINT/.background/background.tiff" 2>/dev/null | grep -c 'Image Width')" -ge 2 ]] \
  && ok "background has 1x and 2x (Retina) images" || die "background resolutions"
swift Scripts/dmg-layout.swift dump "$MOUNT_POINT/.DS_Store" > "$WORK_DIR/ds.txt"
for want in $'.\ticvp' $'.\tbwsp' $'Applications\tIloc' "$APP_NAME"$'\tIloc' "$GUIDE_FILE"$'\tIloc'; do
  grep -qF "$want" "$WORK_DIR/ds.txt" || die ".DS_Store lacks: $want"
done
ok "Finder layout (.DS_Store): icon view, background, icon positions"
swift Scripts/dmg-layout.swift check "$MOUNT_POINT" 2>/dev/null | sed 's/^/    /' || die "background alias/bookmark do not resolve"
ok "background alias and bookmark resolve to the image inside the volume"

echo "▸ App"
PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
EXEC="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$PLIST")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$PLIST")"
[[ -z "$EXPECTED_VERSION" || "$VERSION" == "$EXPECTED_VERSION" ]] && ok "version $VERSION" || die "version $VERSION != $EXPECTED_VERSION"
[[ "$MIN_OS" == "14.0" ]] && ok "LSMinimumSystemVersion $MIN_OS" || die "minimum macOS $MIN_OS"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/$EXEC")"
[[ "$ARCHS" == "arm64" ]] && ok "architecture: $ARCHS only" || die "architecture: $ARCHS"
codesign --verify --strict --deep "$APP" || die "app signature invalid"
ok "app signature valid (strict, deep)"
APP_SIG="$(codesign -dv "$APP" 2>&1 || true)"
[[ "$APP_SIG" == *"Signature=adhoc"* && "$APP_SIG" == *"TeamIdentifier=not set"* ]] || die "app is not ad-hoc signed"
ok "app signature is ad-hoc (no Team ID / Developer ID)"
# 資訊：未公證的 ad-hoc App 預期會被 Gatekeeper 評估為 rejected（使用者需依 README 的「仍要打開」流程）。
GK="$(spctl -a -t exec "$APP" 2>&1 || true)"
ok "Gatekeeper assessment (informational, expected rejected): ${GK##*: }"
[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] || die "icon missing"
ok "AppIcon.icns"
for lproj in zh-Hant en; do
  plutil -lint -s "$APP/Contents/Resources/$lproj.lproj/InfoPlist.strings" || die "$lproj.lproj"
  ok "$lproj.lproj"
done

echo "▸ 卸載"
hdiutil detach -quiet "$MOUNT_POINT"
ok "detached"
echo "DMG verified: $DMG"
