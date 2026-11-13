#!/bin/zsh
# Builds the release disk image on a Mac: tools/release.sh [--publish]
#
# Output in build/release: Dictate-VERSION.dmg and its .sha256, the same Dictate.app in
# stage, and appcast.xml, a feed with this release as its one item. The app is built in the
# Release configuration and signed with a Developer ID under the hardened runtime with a
# secure timestamp; both the app and the image are notarized and stapled, so Dictate opens on
# any Mac without a Gatekeeper warning, offline too. The identity comes from the release
# keychain Blend's tools/release-identity.sh sets up (one Developer ID signs both apps), or
# from VOICE_SIGN_ID and VOICE_NOTARY_PROFILE in your login keychain.
#
# Nothing is published by default: the script prints the command that uploads the image
# with the private download site's publish-release.sh. --publish runs it, and also replaces
# the feed that installed apps read, so only pass it when the release is ready for them.
# VOICE_PUBLISH_TOOL points at publish-release.sh when it isn't in ~/work/dictate-web/tools.
set -euo pipefail
root=${0:A:h:h}
cd $root
version=$(<VERSION)
publish=false
[[ ${1:-} == --publish ]] && publish=true
publishTool=${VOICE_PUBLISH_TOOL:-$HOME/work/dictate-web/tools/publish-release.sh}

identity=${VOICE_SIGN_ID:-}
profile=${VOICE_NOTARY_PROFILE:-}
keychainArgs=()
kc=$HOME/Library/Keychains/blend-release.keychain-db
if [[ -z $identity && -f $kc ]]; then
  security unlock-keychain -p "$(<$HOME/.blend-signing/keychain-password)" $kc
  identity=$(security find-identity -v -p codesigning $kc |
    sed -nE 's/.*"(Developer ID Application: .*)"$/\1/p' | head -1)
  keychainArgs=(--keychain $kc)
  profile=${profile:-blend-notary}
fi
# Release builds run under the hardened runtime, which needs a Developer ID to load the
# embedded frameworks, so there is no ad hoc release; tools/build.sh is for that.
[[ -n $identity && -n $profile ]] || {
  print -u2 "No Developer ID: set up the release keychain, or VOICE_SIGN_ID and VOICE_NOTARY_PROFILE."
  exit 1
}
signFlags=(--timestamp $keychainArgs)

# notarytool exits 0 even when Apple rejects the file, so the status is checked here and a
# rejection prints Apple's reasons.
notarize() {
  local result id
  result=$(xcrun notarytool submit $1 --keychain-profile $profile $keychainArgs --wait \
    --output-format json)
  id=$(print -r -- $result | plutil -extract id raw -o - -)
  if [[ $(print -r -- $result | plutil -extract status raw -o - -) != Accepted ]]; then
    xcrun notarytool log $id --keychain-profile $profile $keychainArgs >&2
    return 1
  fi
  echo "notarized: ${1:t} ($id)"
}

# The Debug build in build/app is left alone, so a Dictate running from it keeps running.
out=$root/build/release
rm -rf $out
mkdir -p $out
(cd app && xcodegen generate --quiet)
xcodebuild -project app/Voice.xcodeproj -scheme Voice -configuration Release \
  -destination "platform=macOS,arch=arm64" -derivedDataPath $out/xcode -quiet \
  MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$version CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$identity" OTHER_CODE_SIGN_FLAGS="$signFlags" build
app=$out/xcode/Build/Products/Release/Dictate.app
# dictate-cli ships inside the app, so `dictate-cli retry-report` and the rest run against the
# installed version: Contents/Helpers/dictate-cli, loading the app's own whisper framework.
# voice-cli is a link to it, for scripts written before the rename.
(cd Core && swift build -c release --product dictate-cli)
mkdir -p $app/Contents/Helpers
cp Core/.build/release/dictate-cli $app/Contents/Helpers/dictate-cli
ln -sf dictate-cli $app/Contents/Helpers/voice-cli
install_name_tool -add_rpath @executable_path/../Frameworks -delete_rpath @loader_path \
  $app/Contents/Helpers/dictate-cli
for rpath in $(otool -l $app/Contents/Helpers/dictate-cli | awk '/LC_RPATH/ {getline; getline; print $2}'); do
  [[ $rpath == /Applications/Xcode* ]] && install_name_tool -delete_rpath $rpath $app/Contents/Helpers/dictate-cli
done
# Notarization needs every piece of code signed with the Developer ID, the hardened runtime
# and a timestamp, and Xcode signs the frameworks it embeds but not the helpers inside
# Sparkle's. So it is signed inside out: Sparkle's helpers in the order its documentation
# gives for an app that isn't sandboxed, then each framework, then the app, whose signature
# covers the frameworks'.
sign() {
  codesign --force --sign "$identity" --options runtime --preserve-metadata=entitlements \
    $signFlags $1
}
for framework in $app/Contents/Frameworks/*(N); do
  if [[ ${framework:t} == Sparkle.framework ]]; then
    helpers=$framework/Versions/B
    for code in $helpers/XPCServices/Installer.xpc $helpers/XPCServices/Downloader.xpc \
      $helpers/Autoupdate $helpers/Updater.app; do
      sign $code
    done
  fi
  sign $framework
done
sign $app/Contents/Helpers/dictate-cli
sign $app
codesign --verify --deep --strict $app

stage=$out/stage
mkdir -p $stage
ditto $app $stage/Dictate.app
# The app gets its own ticket, so it opens without a network check once copied out of the
# image.
ditto -c -k --keepParent $stage/Dictate.app $out/Dictate.zip
notarize $out/Dictate.zip
xcrun stapler staple $stage/Dictate.app
rm $out/Dictate.zip
dmg=$out/Dictate-$version.dmg
# dmgbuild writes the window layout (background, icon positions) into the image's
# .DS_Store directly, so no Finder or AppleScript runs. It lives in a venv, not globally.
dmgbuildVenv=${VOICE_DMGBUILD_VENV:-$HOME/.venvs/dmgbuild}
if [[ ! -x $dmgbuildVenv/bin/dmgbuild ]]; then
  python3 -m venv $dmgbuildVenv
  $dmgbuildVenv/bin/pip install --quiet dmgbuild==1.6.7
fi
rm -f $dmg
$dmgbuildVenv/bin/dmgbuild -s tools/dmg/settings.py -D app=$stage/Dictate.app "Dictate $version" $dmg
codesign --sign "$identity" $signFlags $dmg
notarize $dmg
xcrun stapler staple $dmg
spctl --assess --type execute -v $stage/Dictate.app
spctl --assess --type open --context context:primary-signature -v $dmg
(cd $out && shasum -a 256 ${dmg:t} | tee ${dmg:t}.sha256)
# The notarized image becomes the one item of the update feed. The feed is a file in the
# build folder, uploaded only on request, so a release can be tried without changing what
# installed apps are offered.
sparkle=${VOICE_SPARKLE_DIR:-$HOME/.blend-signing/sparkle-2.10.1}
sparkleKey=${VOICE_SPARKLE_KEY:-$HOME/.blend-signing/sparkle-private-key}
feed=
if [[ -f $sparkleKey ]]; then
  signature=$($sparkle/bin/sign_update --ed-key-file $sparkleKey $dmg)
  feed=$out/appcast.xml
  cat > $feed <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Dictate</title>
    <description>Dictate releases, read by the app's Check for Updates.</description>
    <language>en</language>
    <item>
      <title>Dictate $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure url="https://dictate.firstversion.in/download/$version" $signature type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
else
  print -u2 "No update key at $sparkleKey: no appcast.xml was written."
fi
echo "app: $stage/Dictate.app"
echo "dmg: $dmg"
if $publish; then
  [[ -n $feed ]] || { print -u2 "Not published: the feed needs the update key."; exit 1 }
  [[ -x $publishTool ]] || { print -u2 "Not published: $publishTool is missing."; exit 1 }
  $publishTool $version $dmg $feed
else
  echo "Stage it (not latest, not public, pinned links work):  $publishTool --no-latest $version $dmg${feed:+ $feed}"
  echo "Release it to everyone once checked:                    $publishTool --promote $version   (or rerun with --publish to skip staging)"
fi
