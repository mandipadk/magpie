# Magpie tasks (want 3a54493a)

Magpie is the owner's own iCloud Drive: a Syncthing fork (branch `magpie`, upstream remote
`upstream`) with an always-on encrypted hub in Frankfurt and Mac and iPhone apps that show it in
Finder and Files. Working copy: chicago:~/code/magpie (pushes to frankfurt:~/code/magpie).

## Waiting on the owner (asked 2026-10-19)
- [ ] Repo public or private (ask-me). Public = free Mac builds and a .dmg/appcast anyone can fetch.
- [ ] Oracle ingress TCP+UDP 22000 (errand ffcbaa, running)
- [ ] Root install on Frankfurt: `MAGPIE_ADDR=92.5.139.56:22000 magpie/deploy/install.sh`
      (power sudo timed out on the server side; re-ask)
- [ ] After the repo exists: copy MAC_DEVID_P12/PASSWORD, ASC_KEY_ID/ISSUER_ID/KEY_P8 (power secret
      github from the saved Kestrel secrets), IOS_DEV_P12/PASSWORD (from ~/.config/kestrel/ci-dev),
      SPARKLE_ED_KEY (~/.config/magpie/sparkle-ed25519, made here; public key in apps/mac/project.yml)
- [ ] App Store Connect app record "Magpie" for dev.mandip.magpie (errand, after CI registers the ID)

## 1. Server
- [x] Fork at ~/code/magpie, branch `magpie`; Go 1.27 in ~/.local/go on both servers
- [x] magpie-hubd: init (receive-encrypted folder, staggered versions 1 year, no discovery/relays/
      NAT/UR/upgrades, API on loopback), invites, devices, remove, status JSON
- [x] Deploy kit: magpie-firewall (22000 in, nothing out), hardened units, install.sh, deploy.sh
      (build, test against a real hub, install, health check, roll back)
- [x] Build + tests pass on Frankfurt (deploy.sh --build-only)
- [ ] Installed and running; setup link for the first device on the Magpie page

## 2. Engine (lib/magpie, gomobile bridge lib/magpie/mobile)
- [x] On-demand trusted peer of the encrypted hub: fetch by block (hash checked), upload edits,
      conflict copies (Syncthing naming), resolve (keep both/original/copy), delete, rename, pins
- [x] Tests vs real hub (lib/magpie/hub_test.go): Mac->phone with server unable to read; conflict
      keeps both; delete kept in history; empty files; 10x in a row green
- [x] Invites (cmd/magpie-hubd/main_test.go): first device by server link, second by invite;
      reused/forged/removed devices stay out
- [x] Change log + device list for Finder/Files; builds for darwin and ios
- [ ] Engine tests on the macOS runner (engine job runs on ubuntu)

## 3. Mac app (apps/mac)
- [x] Mockups reviewed by a critic, fixes applied: https://magpie-mockup.mandip.dev
- [x] Code: menu bar panel, Join window, conflicts, Settings (General/Devices/Updates), add device QR,
      File Provider extension (shared), Sparkle, icon (apps/art/icon.py)
- [ ] First CI build; fix compile errors; screens artifact reviewed by the critic
- [ ] Developer ID + notarized dmg on mac-latest, appcast verifies, page links it
- [ ] Real test on the owner's Mac: Finder sidebar, save -> phone, conflict shown, Sparkle update

## 4. iPhone app (apps/ios)
- [x] Code: Home (status, needs you, kept, devices, pause), Join (scan/paste), Add device, conflict sheet
- [ ] First CI build; screens reviewed; TestFlight (needs the App Store record)

## 5. Duties
- [ ] Daily upstream sync (duty, frankfurt): rebase on upstream/main, deploy.sh, push
- [ ] Weekly security review (duty, frankfurt)

## 6. Make it ours (propose, then build)
- Version history in the apps (hub serves its encrypted versions to trusted devices: needs a BEP extension)
- Push nudges from the hub so the iPhone updates without opening Files
