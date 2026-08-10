#!/bin/zsh
# NAICuller.app をビルドして ~/Applications に配置するスクリプト
set -euo pipefail
cd "$(dirname "$0")"

APP="build/NAICuller.app"
mkdir -p "$APP/Contents/MacOS"

swift build -c release

cp ".build/release/NAICuller" "$APP/Contents/MacOS/NAICuller"
cp Info.plist "$APP/Contents/Info.plist"

# ad-hoc署名（未署名だとmacOSが起動を渋ることがあるため）
codesign --force --sign - "$APP"

mkdir -p ~/Applications
rm -rf ~/Applications/NAICuller.app
cp -R "$APP" ~/Applications/NAICuller.app

echo "✅ ~/Applications/NAICuller.app にインストールしたよ"
