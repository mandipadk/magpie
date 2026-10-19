# Magpie tasks (want 3a54493a)

Magpie is the owner's own iCloud Drive: a Syncthing fork (branch `magpie`, upstream remote
`upstream`) with an always-on encrypted hub in Frankfurt and Mac and iPhone apps that show it in
Finder and Files. Working copy: chicago:~/code/magpie (pushes to origin = github.com/mandipadk/magpie,
public, and frankfurt:~/code/magpie). Page: https://magpie.mandip.dev (private, magpie/page).

## Waiting on the owner
- [ ] App Store Connect app record for dev.mandip.magpie (asked with steps, 2026-10-19; the browser
      errand can't, the owner doesn't sign in to Switchback's browser)
- [ ] Real test on their Mac and iPhone (see 3 and 4)

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
- [ ] Signed by hand (Apple Distribution + App Store profiles via asc.py) and uploaded with altool:
      Xcode's own API sign-in failed with the owner's key, though the same key works for the REST API
      and notarytool
- [ ] TestFlight build (needs the App Store record)

## 5. Duties
- [x] 6c6e20 daily: merge upstream, five --build-only passes, deploy, report
- [x] 693e2a weekly (Mon): security review and fixes

## 6. Make it ours (propose, then build)
- Version history in the apps (hub serves its encrypted versions to trusted devices: needs a BEP extension)
- Push nudges from the hub so the iPhone updates without opening Files

## Duties log
