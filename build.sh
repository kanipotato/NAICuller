#!/bin/zsh
# NovelAIViewer.app をビルドして ~/Applications に配置するスクリプト
set -euo pipefail
cd "$(dirname "$0")"

APP="build/NovelAIViewer.app"
mkdir -p "$APP/Contents/MacOS"

swift build -c release

cp ".build/release/NovelAIViewer" "$APP/Contents/MacOS/NovelAIViewer"
cp Info.plist "$APP/Contents/Info.plist"

# ad-hoc署名（未署名だとmacOSが起動を渋ることがあるため）
codesign --force --sign - "$APP"

mkdir -p ~/Applications
rm -rf ~/Applications/NovelAIViewer.app
cp -R "$APP" ~/Applications/NovelAIViewer.app

echo "✅ ~/Applications/NovelAIViewer.app にインストールしたよ"
