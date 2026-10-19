#!/bin/zsh
# Baut zeyt.app nach ./build.
#   ./build.sh                  für diesen Mac
#   ./build.sh install          zusätzlich nach ~/Applications kopieren und starten
#   ./build.sh release 1.2.0    Universal-App (Apple Silicon + Intel), dist/zeyt-1.2.0.zip und dist/zeyt.rb (Homebrew-Cask)
#   ./build.sh uitest           build/zeyt-uitest.app mit Skript-Steuerung für Layout-Tests (UITestScript.swift)
set -euo pipefail
cd "$(dirname "$0")"

MODE=${1:-}
VERSION=${2:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}
VERSION=${VERSION:-0.0.0}
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 0)
ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Info.plist)
APP=build/zeyt.app

if [[ "$MODE" == "release" ]]; then
    swift build -c release --triple arm64-apple-macosx14.0
    swift build -c release --triple x86_64-apple-macosx14.0
    BIN=build/zeyt-universal
    mkdir -p build
    lipo -create .build/arm64-apple-macosx/release/zeyt .build/x86_64-apple-macosx/release/zeyt -output "$BIN"
elif [[ "$MODE" == "uitest" ]]; then
    swift build -c release -Xswiftc -DZEYT_UITEST --scratch-path .build/uitest
    BIN=.build/uitest/release/zeyt
    APP=build/zeyt-uitest.app
else
    swift build -c release
    BIN=.build/release/zeyt
fi

rm -rf "$APP" build/TMR.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/zeyt"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Sources/zeyt/Resources/*.lproj "$APP/Contents/Resources/"
# Ad-hoc, but with a fixed requirement: macOS ties the notification permission to it,
# so it survives updates (the default requirement is the hash of each build).
if [[ "$MODE" == "uitest" ]]; then
    # Own settings domain: the test instance never sees or changes the user's settings (agent token, export script).
    ID=$ID.uitest
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$APP/Contents/Info.plist"
fi
codesign --force --sign - -r="designated => identifier \"$ID\"" "$APP"
echo "Gebaut: $APP ($VERSION)"

case "$MODE" in
install)
    # Fixes go live on real data: keep a copy of it from before each install (the last 30).
    DATA=~/Library/Application\ Support/zeyt
    if [[ -f $DATA/log.csv ]]; then
        BACKUP=$DATA/backups/$(date +%Y-%m-%d_%H%M%S)
        mkdir -p "$BACKUP"
        cp $DATA/log.csv "$BACKUP/"
        [[ -f $DATA/labels.json ]] && cp $DATA/labels.json "$BACKUP/"
        OLD=($DATA/backups/*(/On))   # newest first
        for dir in ${OLD[31,-1]}; do rm -rf "$dir"; done
        echo "Daten gesichert: $BACKUP"
    fi
    pkill -x zeyt || true
    pkill -x Zeyt || true
    pkill -x TMR || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/zeyt.app ~/Applications/TMR.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/zeyt.app
    echo "Installiert: ~/Applications/zeyt.app"
    ;;
release)
    mkdir -p dist
    ZIP=dist/zeyt-$VERSION.zip
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
    sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" packaging/zeyt.rb > dist/zeyt.rb
    echo "Release: $ZIP"
    echo "sha256:  $SHA"
    echo "Cask:    dist/zeyt.rb"
    ;;
esac
