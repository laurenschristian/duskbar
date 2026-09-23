#!/bin/sh
# ./build.sh            build build/DuskBar.app (universal)
# ./build.sh install    build, copy to /Applications, launch
# ./build.sh release    build and package build/DuskBar-v<version>.dmg
# ./build.sh test       unit tests, then perf gates on the installed app
# ./build.sh publish X.Y.Z   bump, tag, GitHub release, update the Homebrew cask
set -e
cd "$(dirname "$0")"
APP=build/DuskBar.app
BIN="$APP/Contents/MacOS/DuskBar"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

if [ "$1" = publish ]; then
  NEW=${2:?usage: ./build.sh publish X.Y.Z}
  TAP=${TAP_DIR:-../homebrew-tap}
  [ -z "$(git status --porcelain)" ] || { echo "working tree not clean"; exit 1; }
  swift test
  BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist) + 1 ))
  /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $NEW" -c "Set CFBundleVersion $BUILD" Info.plist
  sed -i '' "s/DuskBar [0-9.]* |/DuskBar $NEW |/" README.md
  git commit -qam "chore: release $NEW"
  git tag "v$NEW"
  git push -q --follow-tags
  "$0" release
  gh release create "v$NEW" "build/DuskBar-v$NEW.dmg" --title "DuskBar $NEW" --generate-notes
  SHA=$(shasum -a 256 "build/DuskBar-v$NEW.dmg" | cut -d' ' -f1)
  sed -i '' -e "s/version \".*\"/version \"$NEW\"/" -e "s/sha256 \".*\"/sha256 \"$SHA\"/" "$TAP/Casks/duskbar.rb"
  git -C "$TAP" commit -qam "feat: duskbar $NEW"
  git -C "$TAP" push -q
  echo "published $NEW; update with: brew upgrade --cask duskbar"
  exit 0
fi

if [ "$1" = test ]; then
  swift test
  exec scripts/perf-check.sh
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
for arch in arm64 x86_64; do
  swiftc -Osize -whole-module-optimization -module-name DuskBar -target "$arch-apple-macos13.0" \
    Sources/DuskCore/*.swift Sources/DuskBar/*.swift -o "build/DuskBar-$arch"
done
lipo -create build/DuskBar-arm64 build/DuskBar-x86_64 -output "$BIN"
strip -x "$BIN"
rm build/DuskBar-arm64 build/DuskBar-x86_64
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

case "$1" in
  install)
    pkill -x DuskBar || true
    rm -rf /Applications/DuskBar.app
    cp -R "$APP" /Applications/
    open /Applications/DuskBar.app
    ;;
  release)
    STAGE=build/dmg
    rm -rf "$STAGE" "build/DuskBar-v$VERSION.dmg"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -quiet -volname DuskBar -srcfolder "$STAGE" -ov -format UDZO "build/DuskBar-v$VERSION.dmg"
    rm -rf "$STAGE"
    shasum -a 256 "build/DuskBar-v$VERSION.dmg"
    ;;
esac
