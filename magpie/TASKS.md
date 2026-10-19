# Magpie tasks (want 3a54493a)

Magpie is the owner's own iCloud Drive: a Syncthing fork (branch `magpie`, upstream remote
`upstream`) with an always-on encrypted hub in Frankfurt and Mac and iPhone apps that show it in
Finder and Files. Working copy: chicago:~/code/magpie (pushes to origin = github.com/mandipadk/magpie,
public, and frankfurt:~/code/magpie). Page: https://magpie.mandip.dev (private, magpie/page).

## Waiting on the owner
- [ ] iPhone: install from TestFlight (internal group "Owner", app "Space: Magpie"), join with an
      invite from the Mac, then: save on Mac -> shows on phone, a conflict shown, Version history

## Done with the owner (2026-10-19, later)
- [x] App Store Connect record ("Space: Magpie", 6824388726) and App Group group.dev.mandip.magpie
      registered and assigned (owner, from steps)
- [x] Their MacBook Pro joined from the page's setup link (05:32 UTC) and uploaded 6 files, 27 MB;
      reconnected by itself after a hub deploy

## Done with the owner (2026-10-19)
- [x] Repo public; root install on Frankfurt; Oracle ingress TCP+UDP 22000 (owner, from steps)
- [x] CI secrets (8): ASC_KEY_ID/ISSUER_ID/KEY_P8 + MAC_DEVID_P12/PASSWORD from power secret
      apple-signing; IOS_DIST_P12/PASSWORD (CI's own Apple Distribution key, ~/.config/magpie/ci-dist,
      cert TQR6ZP25WT until 2027-10-19); SPARKLE_ED_KEY (~/.config/magpie/sparkle-ed25519)

## 1. Server
- [x] magpie-hubd: init (receive-encrypted folder, staggered versions 1 year, no discovery/relays/
      NAT/UR/upgrades, API on loopback), invites, devices, remove, status JSON
- [x] Deploy kit: magpie-firewall, hardened units, install.sh, deploy.sh (build, test against a real
      hub, install, health check, roll back)
- [x] Installed and running on Frankfurt; deploy.sh run end to end; reachable from outside
      (TLS + ALPN bep/1.0 answered by the hub's certificate from Chicago)
- [x] Magpie page: hub status, devices, Mac download (version from the appcast), first-device
      setup link (only offered once the port is open and an app exists); critic-reviewed

## 2. Engine (lib/magpie, gomobile bridge lib/magpie/mobile)
- [x] On-demand trusted peer of the encrypted hub; tests vs a real hub; invites; change log
- [x] Conflicts carry both versions (device, time, size) for the conflict screens
- [ ] Engine tests on the macOS runner (engine job runs on ubuntu)

## 3. Mac app (apps/mac)
- [x] Compiles in CI; screens reviewed by the critic, fixes applied (jade, pause switch, conflict
      sides, sample data per device, settings tabs captured)
- [x] Developer ID signed, notarized, stapled; Magpie.dmg + appcast on mac-latest; Sparkle signature
      checked against the app's public key from Chicago
- [ ] Real test on the owner's Mac: Finder sidebar, save -> phone, conflict shown, Sparkle update

## 4. iPhone app (apps/ios)
- [x] Compiles in CI; screens reviewed, fixes applied (dark screenshots, camera states, copy)
- [x] Signed by hand (Apple Distribution + App Store profiles via asc.py) and uploaded with altool
      (Xcode's own API sign-in failed with the owner's key; the REST API, notarytool and altool work)
- [x] TestFlight: builds 13 and 15 uploaded; internal group Owner gets every build (asc.py testflight)

## 5. Duties
- [x] 6c6e20 daily: merge upstream, five --build-only passes, deploy, report
- [x] 693e2a weekly (Mon): security review and fixes

## 6. Make it ours (propose, then build)
- [x] Version history, no protocol change: the hub keeps versions in /var/lib/magpie/history and
      shares that directory as a send-only folder (magpie-history); devices fetch a version's
      ciphertext, decrypt its trailer and blocks with the folder key. List, preview, restore, restore a
      copy, bring back deleted files. Engine tests vs a real hub (5x green); hubd migrates older hubs
      (deployed: live hub migrated 06:33 UTC). Mac: Finder "Version History…" window + Settings >
      History; iPhone: Version history in the app
- [ ] Push nudges from the hub so the iPhone updates without opening Files

## Duties log
