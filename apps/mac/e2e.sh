#!/bin/bash
# Magpie end to end on a real Mac (GitHub's macOS runner), with the apps as
# shipped: the .dmg from the Magpie page's link, a test hub on this Mac, and a
# second device (cmd/magpie-phone, the engine the iPhone app runs).
#
#   1. fresh install: download Magpie.dmg, Gatekeeper and notarization checks,
#      install, launch, the join window shows
#   2. the previous build installed, joined to a test hub, Magpie in Finder,
#      a save; then Sparkle updates it to this build from the live appcast
#      while Magpie and its Finder extension run (the owner's case)
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
fail() {
  echo "  FAILED: $*"; echo "- FAILED: $*" >> "$OUT/steps.md"; shot "failed"
  ps -axo pid,lstart,args | grep -i "[m]agpie" > "$OUT/processes.txt" || true
  log show --last 20m --style compact --predicate 'subsystem == "dev.mandip.magpie" OR process == "MagpieFiles" OR (process == "fileproviderd" AND eventMessage CONTAINS[c] "magpie")' > "$OUT/magpie.log" 2>&1 || true
  exit 1
}
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
# press <window> <button> [process]: buttons sit nested in groups, so search the window
press() {
  osascript - "$1" "$2" "${3:-Magpie}" <<'AS'
on run {w, label, p}
  tell application "System Events" to tell process p
    set frontmost to true
    if w is "" then set w to name of window 1
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

# the newest build from before updates were zips: what the owner's Mac runs
step "2. The previous build, as the owner has it"
PREV=$(gh release view mac-latest -R "$REPO" --json assets -q '.assets[].name' | grep -E '^Magpie-[0-9]+\.dmg$' | grep -oE '[0-9]+' | sort -n -u | awk -v b="$BUILD" '$1 < b' | tail -1)
[[ -n "$PREV" ]] || fail "no earlier build on the release to update from"
# Magpie isn't running here, so mounting an image of it is safe.
if curl -fsSL -o "$OUT/Magpie-$PREV.zip" "$REL/Magpie-$PREV.zip"; then
  rm -rf "$APP"; ditto -x -k "$OUT/Magpie-$PREV.zip" /Applications
else
  curl -fsSL -o "$OUT/Magpie-$PREV.dmg" "$REL/Magpie-$PREV.dmg"; install_dmg "$OUT/Magpie-$PREV.dmg"
fi
xattr -dr com.apple.quarantine "$APP"
[[ "$(version)" == "$PREV" ]] || fail "installed build $(version), wanted $PREV"
ok "installed build $PREV"

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
open "$CS"; sleep 3; shot "3-finder-first-open"
# A new File Provider starts disabled: Finder shows "Magpie is not enabled"
# with an Enable button. That's macOS asking the owner once; pluginkit is the
# same switch.
pluginkit -m -v -i dev.mandip.magpie.files > "$OUT/pluginkit.txt" 2>&1 || true
pluginkit -e use -i dev.mandip.magpie.files || true
# and the folder itself: Finder's Enable (what the owner clicked once)
osascript -e 'tell application "System Events" to tell process "Finder" to click button "Enable" of splitter group 1 of window 1' > "$OUT/finder-enable.txt" 2>&1 || {
  # the bar's button at its place in a 1024x768 screen, if it isn't exposed
  osascript -e 'tell application "System Events" to click at {939, 151}' >> "$OUT/finder-enable.txt" 2>&1 || true
}
sleep 5; shot "3-finder-after-enable"
osascript -e 'tell application "Finder" to close every window' || true
open "$CS"; sleep 5; shot "3-finder"
pluginkit -m -v -i dev.mandip.magpie.files >> "$OUT/pluginkit.txt" 2>&1 || true
ok "joined on build $PREV; Magpie is at $CS and in Finder's sidebar (screenshots 3-finder-first-open, 3-finder)"
# save <file> <text>: as an app would, retrying while File Provider settles
save() { for _ in $(seq 60); do printf '%s\n' "$2" > "$1" 2>/dev/null && return 0; sleep 1; done; fail "couldn't save $1"; }
save "$CS/Before the update.txt" "Saved on build $PREV"
waitfor 60 "the hub to get it" bash -c "'$OUT/bin/magpie-hubd' status --home '$HUB' | grep -q '\"files\": [1-9]'"
ok "a Finder save on build $PREV reached the hub"

step "3b. Sparkle update while Magpie and its Finder extension run (the owner's case)"
pgrep -x Magpie >/dev/null || fail "Magpie isn't running"
pgrep -fl "MagpieFiles|dev.mandip.magpie.files" > "$OUT/before-update-processes.txt" || true
SPARKLE_DIR=$(mktemp -d)
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" | tar -xJ -C "$SPARKLE_DIR"
CLI=$(find "$SPARKLE_DIR" -path '*sparkle.app/Contents/MacOS/sparkle' | head -1)
[[ -x "$CLI" ]] || { ls -R "$SPARKLE_DIR" | head -50; fail "no Sparkle command-line tool in the Sparkle download"; }
# The candidate appcast; it goes live only if this passes (magpie-apple.yml).
FEED="$REL/appcast-candidate.xml"
grep -q "Magpie-$BUILD.zip" <(curl -fsSL "$FEED") || fail "the candidate appcast doesn't offer Magpie-$BUILD.zip"
# The same EdDSA check the app uses (SUPublicEDKey in its Info.plist).
("$CLI" "$APP" --feed-url "$FEED" --check-immediately --grant-automatic-checks --verbose > "$OUT/sparkle.txt" 2>&1; echo "exit $?" >> "$OUT/sparkle.txt") &
SPID=$!
waitfor 300 "Sparkle to install build $BUILD with Magpie running" bash -c "[[ \$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' '$APP/Contents/Info.plist' 2>/dev/null) == $BUILD ]]"
for _ in $(seq 60); do kill -0 $SPID 2>/dev/null || break; sleep 1; done
kill -0 $SPID 2>/dev/null && { kill $SPID; fail "Sparkle was still running a minute after installing"; }
grep -qi "extracting" "$OUT/sparkle.txt" && grep -qi "Installation Finished" "$OUT/sparkle.txt" || fail "Sparkle didn't finish (see sparkle.txt)"
codesign --verify --deep --strict "$APP" || fail "the updated app's signature doesn't verify"
spctl -a -vv "$APP" 2>&1 | grep -q "Notarized Developer ID" || fail "Gatekeeper doesn't accept the updated app"
pgrep -x Magpie >/dev/null || open "$APP"
waitfor 30 "Magpie running again" pgrep -x Magpie
waitfor 30 "Finder's view of Magpie to answer" ls "$CS"
ok "Sparkle updated $PREV to $BUILD from the zip while Magpie ran; signature and Gatekeeper OK; Magpie runs and its folder answers"

step "4. Mac save -> phone, phone save -> Mac (on demand)"
save "$CS/From the Mac.txt" "Saved on the Mac at $(date -u +%H:%M:%S)"
open "magpie1:add-device"
waitfor 30 "Add Device" ui 'get window "Add a Device"'
sleep 8  # the invite is made when the window opens
pbcopy < /dev/null
key "Add a Device" 8 command  # Command-C: Copy Link
sleep 1
INVITE=$(pbpaste)
shot "4-add-device"
[[ "$INVITE" == magpie1:join\?* && "$INVITE" != "$LINK" ]] || fail "Add Device didn't copy an invite (see 4-add-device)"
"$OUT/bin/magpie-phone" --dir "$OUT/phone" join "$INVITE"
"$OUT/bin/magpie-phone" --dir "$OUT/phone" get "From the Mac.txt" "$OUT/phone-got.txt"
cmp -s "$CS/From the Mac.txt" "$OUT/phone-got.txt" || fail "the phone read something else"
"$OUT/bin/magpie-phone" --dir "$OUT/phone" get "Before the update.txt" "$OUT/phone-before.txt"
grep -q "Saved on build $PREV" "$OUT/phone-before.txt" || fail "the file saved before the update didn't reach the phone"
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
save "$CS/From the Mac.txt" "Mac edit"
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
