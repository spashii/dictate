#!/bin/zsh
# Draws the app's windows from made-up data on a Mac: tools/demo-render.sh OUTDIR
# A Debug build with its own bundle identifier, so the installed app's preferences stay
# untouched, and a throwaway support folder, so its recordings and database do too.
set -euo pipefail
root=${0:A:h:h}
out=${1:?usage: tools/demo-render.sh OUTDIR}
cd $root/app
xcodegen generate --quiet
xcodebuild -project Voice.xcodeproj -scheme Voice -configuration Debug -destination "platform=macOS,arch=arm64" \
  -derivedDataPath $root/build/demo -quiet CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  PRODUCT_BUNDLE_IDENTIFIER=io.github.spashii.voice.demo build
support=/tmp/voice-demo-home
rm -rf $support $out; mkdir -p $support $out
VOICE_DEMO_SUPPORT=$support VOICE_DEMO_OUT=$out \
  $root/build/demo/Build/Products/Debug/Voice.app/Contents/MacOS/Voice
defaults delete io.github.spashii.voice.demo 2>/dev/null || true
rm -rf $support
