#!/bin/zsh
# NAICuller.app をリリースビルドし、配布用の.dmgを dist/ に作るスクリプト。
# build.sh（開発機の~/Applicationsへの配置用）とは目的が異なるため分離した。
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
APP_NAME="NAICuller"
APP="build/${APP_NAME}.app"
DIST_DIR="dist"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
STAGING_DIR="${DIST_DIR}/dmg-staging"

echo "==> ${APP_NAME} ${VERSION} をリリースビルド中..."
mkdir -p "$APP/Contents/MacOS"
swift build -c release
cp ".build/release/${APP_NAME}" "$APP/Contents/MacOS/${APP_NAME}"
cp Info.plist "$APP/Contents/Info.plist"

# ad-hoc署名（Apple Developer証明書は未登録のため）。ダウンロードした人がFinderで開くと
# quarantine属性により「壊れているため開けません」と出ることがある。README側に
# 「右クリック→開く」または`xattr -cr`での回避方法を案内する前提。
codesign --force --sign - "$APP"

echo "==> .dmg を作成中..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP" "$STAGING_DIR/${APP_NAME}.app"
# Finderでdmgを開いたときに「Appを/Applicationsへドラッグ」で入れられるよう、
# エイリアス（シンボリックリンク）を同梱するのが定番の配布形式。
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "${DIST_DIR}/${DMG_NAME}"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "${DIST_DIR}/${DMG_NAME}"
rm -rf "$STAGING_DIR"

echo "✅ ${DIST_DIR}/${DMG_NAME} を作成したよ"
