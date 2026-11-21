#!/bin/zsh
# MeetNote をビルドする。--install を付けると ~/Applications にコピーする。
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet

# 固定の署名用証明書（scripts/setup-signing.sh で作る）があれば使う。無ければその場かぎりの署名になる。
IDENTITY="-"
if security find-identity -v -p codesigning | grep -q "MeetNote Local Signing"; then
  IDENTITY="MeetNote Local Signing"
fi

xcodebuild -project MeetNote.xcodeproj -scheme MeetNote -configuration Release \
  -derivedDataPath build -quiet build CODE_SIGN_IDENTITY="$IDENTITY"
APP="build/Build/Products/Release/MeetNote.app"
echo "ビルド完了: $PWD/$APP"
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/MeetNote.app"
  cp -R "$APP" "$HOME/Applications/MeetNote.app"
  echo "インストール完了: $HOME/Applications/MeetNote.app"
fi
