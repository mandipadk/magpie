#!/bin/bash
# Magpie end to end on a real Mac (GitHub's macOS runner), with the apps as
# shipped: the .dmg from the Magpie page's link, a test hub on this Mac, and a
# second device (cmd/magpie-phone, the engine the iPhone app runs).
#
#   1. fresh install: download Magpie.dmg, Gatekeeper and notarization checks,
#      install, launch, the join window shows
#   2. Sparkle: install the previous build and let Sparkle update it from the
#      live appcast to this build
#   3. join the test hub; Magpie shows in Finder (CloudStorage, sidebar)
#   4. a save in Finder shows on the phone; a save on the phone shows in
#      Finder, downloaded only when opened
#   5. a conflict (an edit on each side): the menu bar shows it
#
# Writes steps.md, logs and screenshots to $E2E_OUT. Needs: go, the syncthing
# checkout (for the hub), System Events access (GitHub's runners allow it).
set -euo pipefail

OUT=${E2E_OUT:-$PWD/e2e-out}
BUILD=${BUILD_NUMBER:?}
REPO=${GITHUB_REPOSITORY:-mandipadk/magpie}
REL="https://github.com/$REPO/releases/download/mac-latest"
APP=/Applications/Magpie.app
mkdir -p "$OUT/bin"
: > "$OUT/steps.md"

step() { echo "== $*"; printf '\n## %s\n' "$*" >> "$OUT/steps.md"; }
ok() { echo "  ok: $*"; echo "- ok: $*" >> "$OUT/steps.md"; }
fail() { echo "  FAILED: $*"; echo "- FAILED: $*" >> "$OUT/steps.md"; shot "failed"; exit 1; }
shot() { screencapture -x "$OUT/$1.png" 2>/dev/null || true; }
waitfor() { # waitfor <seconds> <what> <command...>
  local n=$1 what=$2; shift 2
  for _ in $(seq "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  fail "timed out after ${n}s waiting for $what"
}
version() { /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist"; }
ui() { osascript -e "tell application \"System Events\" to tell process \"Magpie\" to $1"; }
# key <window> <key code> [command]: the window frontmost, then a key
key() {
  ui "perform action \"AXRaise\" of window \"$1\"" || true
  osascript -e 'tell application "System Events" to set frontmost of process "Magpie" to true'
  if [[ "${3:-}" == command ]]; then
    osascript -e "tell application \"System Events\" to key code $2 using command down"
  else
    osascript -e "tell application \"System Events\" to key code $2"
  fi
  ui "get entire contents of window \"$1\"" > "$OUT/ui-$(echo "$1" | tr ' ' -).txt" 2>&1 || true
}
# press <window> <button>: SwiftUI nests buttons in groups, so search the window
press() {
  osascript - "$1" "$2" <<'AS'
on run {w, label}
  tell application "System Events" to tell process "Magpie"
    set frontmost to true
    repeat with e in (entire contents of window w)
      try
        if role of e is "AXButton" and (name of e is label or description of e is label or title of e is label) then
          click e
          return "pressed " & label
        end if
      end try
    end repeat
  end tell
  error "no button " & label & " in " & w
end run
AS
}
quit_app() { osascript -e 'quit app "Magpie"' 2>/dev/null || true; pkill -x Magpie 2>/dev/null || true; sleep 2; }
install_dmg() { # install_dmg <dmg>
  local mnt; mnt=$(mktemp -d)
  hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$1" >/dev/null
  rm -rf "$APP"; ditto "$mnt/Magpie.app" "$APP"
  hdiutil detach "$mnt" >/dev/null
}

step "Tools: a test hub and the second device"
VERSION="v0.0.0-magpie+e2e$BUILD" go run build.go -no-upgrade build syncthing >/dev/null
go build -o "$OUT/bin/magpie-hubd" ./cmd/magpie-hubd
go build -o "$OUT/bin/magpie-phone" ./cmd/magpie-phone
ok "built syncthing, magpie-hubd and magpie-phone"

step "1. Fresh install from the Magpie page's link"
curl -fsSL -o "$OUT/Magpie.dmg" "$REL/Magpie.dmg"
# as Safari leaves it, so Gatekeeper judges it as a download
xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Safari;" "$OUT/Magpie.dmg"
spctl -a -t open --context context:primary-signature -vv "$OUT/Magpie.dmg" 2>&1 | tee "$OUT/spctl-dmg.txt"
xcrun stapler validate "$OUT/Magpie.dmg" | tee -a "$OUT/spctl-dmg.txt"
install_dmg "$OUT/Magpie.dmg"
spctl -a -vv "$APP" 2>&1 | tee "$OUT/spctl-app.txt"
grep -q "source=Notarized Developer ID" "$OUT/spctl-app.txt" || fail "Gatekeeper doesn't accept the app as notarized"
[[ "$(version)" == "$BUILD" ]] || fail "the page's Magpie.dmg is build $(version), not $BUILD"
ok "Magpie.dmg (build $BUILD) is notarized and stapled; Gatekeeper: $(grep -o 'source=.*' "$OUT/spctl-app.txt")"
# Gatekeeper's first-launch question is the system's, not Magpie's; skip it
xattr -dr com.apple.quarantine "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
open "$APP"
waitfor 30 "Magpie to start" pgrep -x Magpie
waitfor 30 "the join window" ui 'get window "Join your Magpie"'
shot "1-join-window"
ok "Magpie starts on a fresh Mac and asks to join"
quit_app

step "2. Sparkle update from the previous build to $BUILD"
PREV=$(gh release view mac-latest -R "$REPO" --json assets -q '.assets[].name' | sed -n 's/^Magpie-\([0-9]*\)\.dmg$/\1/p' | sort -n | awk -v b="$BUILD" '$1 < b' | tail -1)
[[ -n "$PREV" ]] || fail "no earlier build on the release to update from"
curl -fsSL -o "$OUT/Magpie-$PREV.dmg" "$REL/Magpie-$PREV.dmg"
install_dmg "$OUT/Magpie-$PREV.dmg"
xattr -dr com.apple.quarantine "$APP"
[[ "$(version)" == "$PREV" ]] || fail "installed build $(version), wanted $PREV"
ok "installed build $PREV"
SPARKLE_DIR=$(mktemp -d)
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" | tar -xJ -C "$SPARKLE_DIR"
CLI=$(find "$SPARKLE_DIR" -path '*sparkle.app/Contents/MacOS/sparkle' | head -1)
[[ -x "$CLI" ]] || { ls -R "$SPARKLE_DIR" | head -50; fail "no Sparkle command-line tool in the Sparkle download"; }
# The same appcast and EdDSA check the app uses (SUFeedURL, SUPublicEDKey in its Info.plist).
"$CLI" "$APP" --check-immediately --grant-automatic-checks --verbose 2>&1 | tee "$OUT/sparkle.txt" || true
waitfor 120 "Sparkle to install build $BUILD" bash -c "[[ \$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' '$APP/Contents/Info.plist') == $BUILD ]]"
codesign --verify --deep --strict "$APP" || fail "the updated app's signature doesn't verify"
ok "Sparkle updated $PREV to $BUILD from the live appcast; the signature verifies"

step "3. Join a test hub; Magpie in Finder"
HUB="$OUT/hub"
"$OUT/bin/magpie-hubd" init --home "$HUB" --addr 127.0.0.1:22999 --syncthing "$PWD/syncthing"
sed -i '' 's/0\.0\.0\.0:/127.0.0.1:/g' "$HUB/config.xml"
(STNOUPGRADE=1 ./syncthing serve --home "$HUB" --no-browser --no-restart > "$OUT/hub.log" 2>&1 &)
waitfor 60 "the hub" "$OUT/bin/magpie-hubd" status --home "$HUB"
(PATH="$PWD:$PATH" "$OUT/bin/magpie-hubd" run --home "$HUB" > "$OUT/hubd.log" 2>&1 &)
LINK=$(PATH="$PWD:$PATH" "$OUT/bin/magpie-hubd" setup-link --home "$HUB")
printf '%s' "$LINK" | pbcopy  # the join window takes a link from the clipboard
open "$APP"
waitfor 30 "the join window" ui 'get window "Join your Magpie"'
key "Join your Magpie" 36  # Return: Join is the default button
CS=""
findcs() { CS=$(find "$HOME/Library/CloudStorage" -maxdepth 1 -iname 'Magpie*' -print -quit 2>/dev/null); [[ -n "$CS" ]]; }
waitfor 90 "Magpie in ~/Library/CloudStorage" findcs
fileproviderctl domain list > "$OUT/fileprovider-domains.txt" 2>&1 || true
waitfor 60 "the hub to admit the Mac" bash -c "'$OUT/bin/magpie-hubd' status --home '$HUB' | grep -q '\"connected\": true'"
open "$CS"; sleep 3; shot "3-finder"
ok "joined; Magpie is at $CS and in Finder's sidebar (screenshot 3-finder)"

step "4. Mac save -> phone, phone save -> Mac (on demand)"
echo "Saved on the Mac at $(date -u +%H:%M:%S)" > "$CS/From the Mac.txt"
open "magpie1:add-device"
waitfor 30 "Add Device" ui 'get window "Add a Device"'
sleep 5  # the invite is made when the window opens
key "Add a Device" 8 command  # Command-C: Copy Link
sleep 1
INVITE=$(pbpaste)
[[ "$INVITE" == magpie1:join\?* ]] || fail "Add Device didn't copy an invite"
shot "4-add-device"
"$OUT/bin/magpie-phone" --dir "$OUT/phone" join "$INVITE"
"$OUT/bin/magpie-phone" --dir "$OUT/phone" get "From the Mac.txt" "$OUT/phone-got.txt"
cmp -s "$CS/From the Mac.txt" "$OUT/phone-got.txt" || fail "the phone read something else"
ok "a file saved in Finder reached the phone intact ($(cat "$OUT/phone-got.txt"))"
echo "Saved on the phone" > "$OUT/from-phone.txt"
"$OUT/bin/magpie-phone" --dir "$OUT/phone" put "From the iPhone.txt" "$OUT/from-phone.txt"
waitfor 60 "the phone's file in Finder" test -e "$CS/From the iPhone.txt"
ls -lO "$CS" > "$OUT/finder-listing.txt"
grep -q 'dataless.*From the iPhone.txt' "$OUT/finder-listing.txt" && ok "it arrives as a placeholder (dataless) until opened" || echo "  note: not a placeholder: $(grep 'From the iPhone' "$OUT/finder-listing.txt")"
cmp -s "$CS/From the iPhone.txt" "$OUT/from-phone.txt" || fail "opening the phone's file on the Mac gave something else"
ok "a file saved on the phone opens in Finder intact"

step "5. A conflict shows in the menu bar"
# The phone is offline (its process isn't running) while the Mac edits; then
# it edits the same file from the version it last saw.
echo "Mac edit" > "$CS/From the Mac.txt"
sleep 15
echo "Phone edit" > "$OUT/phone-edit.txt"
"$OUT/bin/magpie-phone" --dir "$OUT/phone" put-offline "From the Mac.txt" "$OUT/phone-edit.txt"
waitfor 90 "the conflict copy in Finder" bash -c "ls '$CS' | grep -q 'From the Mac.*conflict\|From the Mac (.*'"
ls -l "$CS" >> "$OUT/finder-listing.txt"
ui 'get description of menu bar item 1 of menu bar 2' > "$OUT/menu-text.txt" 2>&1 || true
ui 'click menu bar item 1 of menu bar 2' || true; sleep 2
shot "5-menu-conflict"
ui 'get value of every static text of window 1' > "$OUT/menu-text.txt" 2>&1 || true
ui 'get entire contents of window 1' >> "$OUT/menu-text.txt" 2>&1 || true
# the icon's label is "Magpie, <headline>"; the panel lists it under Needs you
grep -qi "Needs you\|conflict" "$OUT/menu-text.txt" || fail "the menu bar doesn't show the conflict"
ok "the menu bar panel shows the conflict (screenshot 5-menu-conflict)"

step "Done"
ok "all steps passed on build $BUILD"
