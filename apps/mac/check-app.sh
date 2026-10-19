#!/usr/bin/env bash
# Checks a built Magpie.app the way macOS will: the File Provider extension is
# inside, declared and entitled correctly, everything is signed with the
# Developer ID and the hardened runtime, and Sparkle can verify updates.
#   apps/mac/check-app.sh /path/to/Magpie.app
set -uo pipefail
APP=${1:?usage: check-app.sh Magpie.app}
EXT="$APP/Contents/PlugIns/MagpieFiles.appex"
fail=0
bad() { echo "::error::$*"; fail=1; }

[[ -d "$EXT" ]] || bad "no File Provider extension at Contents/PlugIns/MagpieFiles.appex"
[[ $(plutil -extract NSExtension.NSExtensionPointIdentifier raw "$EXT/Contents/Info.plist" 2>/dev/null) == com.apple.fileprovider-nonui ]] \
  || bad "the extension is not a File Provider extension"
[[ $(plutil -extract NSExtension.NSExtensionPrincipalClass raw "$EXT/Contents/Info.plist" 2>/dev/null) == MagpieFiles.FileProviderExtension ]] \
  || bad "the extension's principal class is not MagpieFiles.FileProviderExtension"
nm "$EXT/Contents/MacOS/MagpieFiles" 2>/dev/null | grep -q FileProviderExtension || echo "note: the class name isn't visible in a stripped binary"

ents() { codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -convert json -o - - 2>/dev/null; }
E=$(ents "$EXT")
echo "$E" | grep -q '"com.apple.security.app-sandbox":true' || bad "the extension is not sandboxed (File Provider extensions must be)"
echo "$E" | grep -q 'UK74VYMUP7.dev.mandip.magpie' || bad "the extension lacks the app group"
echo "$E" | grep -q '"com.apple.security.network.client":true' || bad "the extension can't make network connections"
A=$(ents "$APP")
echo "$A" | grep -q 'UK74VYMUP7.dev.mandip.magpie' || bad "the app lacks the app group"
echo "$A" | grep -q 'UK74VYMUP7.dev.mandip.magpie.shared' || bad "the app lacks the shared keychain group"

for target in "$APP" "$EXT" "$APP/Contents/Frameworks/Sparkle.framework"; do
  codesign --verify --strict --deep "$target" 2>&1 || bad "signature check failed: $target"
  info=$(codesign -dvv "$target" 2>&1)
  echo "$info" | grep -q "Authority=Developer ID Application" || bad "not signed with Developer ID: $target"
  echo "$info" | grep -q "flags=.*runtime" || bad "no hardened runtime: $target"
done
# The extension's service only answers the app (Magpie.appRequirement).
REQ=$(sed -n 's/.*static let appRequirement = #"\(.*\)"#.*/\1/p' "$(dirname "$0")/../shared/MagpieCore.swift")
[[ -n "$REQ" ]] || bad "no appRequirement in MagpieCore.swift"
codesign --verify --test-requirement="=$REQ" "$APP" 2>&1 || bad "the app doesn't meet the service's requirement: $REQ"
codesign --verify --test-requirement="=$REQ" "$EXT" >/dev/null 2>&1 && bad "the extension meets the app-only requirement (too loose): $REQ"
[[ -n $(plutil -extract SUFeedURL raw "$APP/Contents/Info.plist" 2>/dev/null) ]] || bad "no Sparkle feed URL"
[[ -n $(plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist" 2>/dev/null) ]] || bad "no Sparkle public key"
[[ $(plutil -extract LSUIElement raw "$APP/Contents/Info.plist" 2>/dev/null) == true ]] || bad "the app would show a Dock icon"

if otool -L "$EXT/Contents/MacOS/MagpieFiles" | grep -E '^\s+\S' | grep -vE '^\s+(/usr/lib/|/System/Library/|@rpath/libswift)'; then
  bad "the extension links a library that is not part of macOS"
fi
[[ $fail == 0 ]] && echo "Magpie.app: ok"
exit $fail
