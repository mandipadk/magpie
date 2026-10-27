# Magpie tasks (want 3a54493a)

Magpie is the owner's own iCloud Drive: a Syncthing fork (branch `magpie`, upstream remote
`upstream`) with an always-on encrypted hub in Frankfurt and Mac and iPhone apps that show it in
Finder and Files. Working copy: chicago:~/code/magpie (pushes to origin = github.com/mandipadk/magpie,
public, and frankfurt:~/code/magpie). Page: https://magpie.mandip.dev (private, magpie/page).

## Waiting on the owner
- [x] iPhone joined from the Mac's Add Device and shows the Mac's files (owner, build 43, 2026-10-21)

## The page as an app (owner, 2026-10-19 ~19:10)
- [x] Rebuilt from Kiln app parts (Kiln e95a578): top bar with a status Tag and the theme menu; Stat
      for files, storage, older versions and uptime; Surface panels; a Table of devices with an
      Online/Offline Tag, last activity and Remove (Dialog); Add a device, Browse, Download and Open
      TestFlight as real buttons; no run-in statements or display type

## Kiln page and the iPhone app's connection (2026-10-19, evening)
- [x] Page rebuilt on Kiln (github:mandipadk/designsystem @d5e4642): magpie/page/web (React, Kiln
      components, tokens, Mona Sans, Kiln's theme menu), built into magpie/page/dist and served by
      server.mjs. Hub status is the hero; devices show state words and since/last seen (hubd now
      reports connectedAt); apps show their facts. Kiln's rules over two critic asks: a state is a
      word (no dots), facts never joined with dots. Critic: 8/10, then its fixes
- [x] Owner (photo, build 40): the app said "Starting", 0 devices, Pause did nothing; Files showed the
      folder with "Syncing with Magpie paused". The app reached the extension through the Files URL,
      which an iPhone app can't open, so it never connected. Now via NSFileProviderManager.getService
      (build 43; the Mac e2e runs that path through Add Device, green)
- [x] Owner (2026-10-21): build 43 says Up to date and a Mac file opens in the Files app
- [ ] Owner's Mac: update from build 10 not confirmed (the hub can't tell a device's build)

## iPhone joined (2026-10-19 18:02 UTC), but doesn't stay connected
- [x] Hub admitted J7RG4PP ("iPhone") at 18:02 with a valid invite (so from the Mac, with the key)
- [x] Every iPhone connection ended ~1 s after it opened. Owner (build 39): app says "Starting", no
      files, JetsamEvent logs: iOS killed the Files extension for memory. Measured one connection at
      53 MB peak (scrypt to derive the folder key, 32 MiB, on every launch).
- [x] Fix (build 40): the app derives the key once and keeps it in the keychain config (folderKey);
      kept configs get it when the app starts; the extension never runs scrypt; Go memory limit
      24 MiB. Reconnect peak measured 19.8 MB (was 53). TestPrepareConfig; e2e green
- [x] After build 40: the iPhone connected at 18:32:04 UTC and stayed connected (3+ min, no drops);
      hub sees its state as valid and sent it the index (35 KB). Files on the phone not seen by me

## CRITICAL: update from build 10 to 22 hung at Extracting (owner, 2026-10-19 ~15:00)
- Owner's assistant: build 22's dmg and signature are fine; mounting it with hdiutil on that Mac hung
  and the Mac froze to a black screen. Magpie's File Provider extension was running while the image
  held a second copy of it. Kestrel's dmg update worked on the same Mac.
- [x] Live appcast emptied (no update offered) at ~15:10 UTC; old copy kept in the scratchpad
- [x] Updates now ship as Magpie-N.zip (stapled app), never a disk image; the page's Magpie.dmg is
      for first installs only, and says to quit Magpie before opening a new download
- [x] One engine per device's files (flock); a second extension copy gets ErrBusy (TestDataDirLock)
- [x] Gate: CI publishes appcast-candidate.xml; the e2e job updates a running, joined build 25
      (last dmg build) with it and only then makes it appcast.xml
- [x] e2e green on that path (run 39294365848: build 25 running and joined, Sparkle to 36 from the
      zip, then Add Device, Mac <-> phone, on-demand open, conflict in the menu bar); the gate made
      build 36 the live appcast (~17:40 UTC)
- [x] Found on the way: the one-process lock (my change, builds 27-32) locked out macOS's second
      extension process, so the updated Mac's engine never opened; removed (build 33+). Add Device
      said "isn't reachable" when opened before the app connected; it now waits. A restored join
      window showed on a joined Mac after an update; now closes
- [ ] Owner: Check for Updates on the Mac (build 10 -> latest, live after e2e run 39298090535), then the page's Add a device
- Open: macOS runs the extension in two processes, each opening the engine on the same files.
  Worked for hours on the owner's Mac; needs one engine owner per device (design, not a lock)
- Not known: what exactly froze the Mac (no access to it). Not repeated on purpose.

## Critic round (2026-10-19, 14:00) and the owner's page correction
- [x] Page "Add a device": the owner meant the page's button, gone once a device existed. A page link
      can't carry the encryption key (the hub never has it), so the button opens the Mac's Add Device
      (magpie1:add-device) with the QR and link; elsewhere the page says to open it on the Mac
- [x] Page: magpie mark (apps/art/magpie.svg, also the app icons and join screens), Inter 700
      headings, heavier Mac/iPhone titles, less space above the footer, TestFlight line in plain words
- [x] Page: older versions say when one was last kept and link "Browse in Magpie" (magpie1:history)
- [x] Hub: 6 versions kept before history existed were stranded in .stversions; hubd moves them
      into the history folder (deployed 30eadb32921b: 6 versions, 27 MB, visible to devices)
- [x] Revocation: removing a device (page "Remove", or magpie-hubd remove) replaces the invite key;
      the hub publishes it in the history folder to the devices still in; a removed device's invites
      are refused (TestJoinByInvite vs a real hub, 3x green). Deployed.
- [x] E2E on a fresh Mac in CI (apps/mac/e2e.sh, job e2e): page dmg + Gatekeeper, Sparkle 20 -> 22,
      join, Finder, Mac save -> phone engine, phone -> Mac on demand, conflict in the menu bar
- [x] SCOPE.md: what is and isn't tested

## Owner reports (2026-10-19, afternoon)
- [x] "Add a device button is gone": it sat in the device list's section footer, which a grouped Form
      drops when the list is empty (the app hadn't reached the extension yet). Now always visible
      under the list, with a "Connecting to Magpie…" row, and Add Device… is in the menu bar panel
- [x] Page said "On TestFlight soon": now "In TestFlight as Space: Magpie" with Get TestFlight

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
- [ ] iPhone extension service answers any app it hands an item to (security review 2026-10-26):
      the macOS service is code-signing-gated, the iOS one isn't, so an app given a Magpie file could
      call invite() and get the folder password and invite key. Fix: a per-call secret from the
      shared keychain group (at least for invite()); needs testing on the owner's iPhone.
- [ ] Invite key kept in a plaintext file in the engine folder (lib/magpie/keys.go, since the key
      rotation, 2026-10-19), which backups include. Keep it in the keychain config, or exclude the
      engine folder from backups with complete file protection.
- [ ] magpie1:join links: the iPhone joins a not-yet-joined device straight from a link, with no
      confirmation; show the hub's address and ID and ask first (Mac and iPhone).
- [x] Real lock-out for a removed device (security review 2026-10-19; done the same day, see above): every device holds the hub's
      invite key and the folder password, so a removed (e.g. stolen) device can mint a fresh token
      and join again. Proposal: hub-issued invites over the device's own connection (or per-device
      invite keys the hub can revoke), and a password rotation path. Needs app changes.

## Duties log
- 2026-10-19 (6c6e20): merged upstream 775573cb2 (GUI about-dialog contributors only) as 3186d2126,
  no conflicts; Frankfurt `deploy.sh --build-only` 5/5 green (lib/magpie, cmd/magpie-hubd vs real hub);
  pushed origin + frankfurt. Deployed after the owner allowed it (`power run`, ~14:00 UTC):
  deploy.sh built 20f7f3b12deb (merge + the security review's fixes), tests green, installed;
  status: v2.1.7-rc.3.dev.43.g20f7f3b1-magpie, folderErrors 0, encrypted, 6 files.
- 2026-10-19 (693e2a, weekly security review). Checked: govulncheck on lib/magpie, cmd/magpie-hubd,
  cmd/syncthing (source) and the deployed syncthing + magpie-hubd binaries: nothing reachable (only
  GO-2026-5932, x/crypto/openpgp, not imported); Go 1.27.2 is current; no new Syncthing or quic-go
  advisories that touch us (quic-go v0.63.0; the 2026-05 QPACK one is HTTP/3 only). Hub: only 22000
  tcp/udp public for Magpie, API on 127.0.0.1:8385, folder receiveencrypted, no plaintext outside
  *.syncthing-enc (spot-checked file: entropy 7.96 bits/byte), firewall check ok, devices = the
  owner's MacBook Pro only, invite used list 1 entry (05:32, the Mac), no connection floods (279
  "Failed TLS handshake" in a day are all from Chicago: the page's port probe, once a minute). GitHub:
  exactly the 8 secrets, no third-party actions, upstream workflows disabled or owner-guarded, no
  secrets in the tree or history.
  Fixed (c9cf7e466): the Mac extension's XPC service answered any local process (invites carry the
  password and invite key): now code-signing-gated to the Magpie app, checked by check-app.sh; CI
  verifies the Sparkle tarball's SHA-256 before sign_update gets the key; first-party actions pinned
  to commits; upstream update-docs-translations (contents: write, Mondays) guarded to syncthing; the
  engine drops non-clean names from other devices (TestValidFiles); hubd status counted history in
  the old .stversions (TestJoinByInvite). Frankfurt --build-only 3/3 green. CI run 39237564033 green
  (check-app passes the requirement, Sparkle tarball OK; Mac update and TestFlight build published).
  Hub deployed 20f7f3b12deb after the owner allowed it (10:43 UTC): healthy, firewall ok, Mac reconnected.
  Not fixed: removed devices can rejoin with the invite key (task above). Left alone: a stale
  /var/lib/magpie/.syncthing.tmp.522431330 from 04:11 (0600, magpie); rpcbind on 0.0.0.0:111 on
  Frankfurt (not Magpie). Not testable here: the XPC gate on a real Mac (CI checks the signature
  matches); iPhone: the gate is macOS-only for now (other apps reach the service only for items the user hands them).
- 2026-10-20 (6c6e20): upstream/main still 775573cb2, already merged; nothing to take. Frankfurt
  `deploy.sh --build-only` 5/5 green on 62b7d8dee (lib/magpie, cmd/magpie-hubd vs real hub);
  deployed 62b7d8dee401 (was 3ba58ff8; changes since are page/app only). Status:
  v2.1.7-rc.3.dev.88.g62b7d8de-magpie, folderErrors 0, encrypted, 6 files.
- 2026-10-21 (6c6e20): merged upstream d6d0181f7 (fix(model): compare blocks when reconciling
  receive-only, #10929; one line in lib/model/folder.go) as ab5302501, no conflicts. Frankfurt
  `deploy.sh --build-only` failed 1 of 5: TestHubDeleteKeepsHistory, hub API "bind: address already
  in use" because the test picked the GUI and listen ports one after the other and got the same one.
  Fixed in the tests (35b368a8e, freePorts holds both listeners; lib/magpie and cmd/magpie-hubd);
  then 10/10 green. Deployed 35b368a8e358. Status: v2.1.7-rc.3.dev.92.g35b368a8-magpie,
  folderErrors 0, encrypted, 6 files (Mac and iPhone not connected at the time).
- 2026-10-22 (c73277cd): upstream/main still d6d0181f7, already merged; nothing to take. No engine
  or hub code changes since the deployed 35b368a8e (only docs), so no rebuild or redeploy. Status:
  v2.1.7-rc.3.dev.92.g35b368a8-magpie, folderErrors 0, encrypted, 6 files, Mac connected.
- 2026-10-23 (c6c00af8): merged upstream a4a2da477 (fix(model): skip ignored folders when
  auto-accepting, #10935; lib/model only) as f40c14cb4, no conflicts. Frankfurt
  `deploy.sh --build-only` 5/5 green on f40c14cb4 (lib/magpie, cmd/magpie-hubd vs real hub);
  pushed origin + frankfurt. Deploy blocked by the session's safety check; sent to the owner via
  `power run` (request timed out waiting for the tap). Hub still on 35b368a8e
  (v2.1.7-rc.3.dev.92.g35b368a8-magpie), Mac connected.
- 2026-10-24 (80310133): upstream/main still a4a2da477, already merged; nothing to take. Yesterday's
  pending deploy did go through (hub uptime ~18 h): status v2.1.7-rc.3.dev.98.g0102f0e5-magpie =
  magpie HEAD before this entry, folderErrors 0, encrypted, 6 files; Mac last seen 09:29 UTC, iPhone
  10-22. No engine or hub changes since, so no rebuild or redeploy.
- 2026-10-25 (3b83063d): upstream/main still a4a2da477, already merged; nothing to take. Hub status
  v2.1.7-rc.3.dev.98.g0102f0e5-magpie, folderErrors 0. No engine or hub changes since (only TASKS),
  so no redeploy. Frankfurt `deploy.sh --build-only` 5/5 green on 2c182b6d6 (lib/magpie,
  cmd/magpie-hubd vs real hub).
- 2026-10-26 (5f8adfe8): merged upstream 70b5bc78c (chore: docs, translations, contributors; GUI
  and man pages only) as 3a394236d, no conflicts. Frankfurt `deploy.sh --build-only` 5/5 green on
  3a394236d (lib/magpie, cmd/magpie-hubd vs real hub); pushed origin + frankfurt. Deploy blocked by
  the session's safety check; sent to the owner via `power run`, allowed ~13:50 UTC. By then the
  weekly security review had pushed aa6895477 + c01edc54c on top (its own --build-only 5/5), so
  deploy.sh built, tested (green) and installed c01edc54c274. Status:
  v2.1.7-rc.3.dev.106.gc01edc54-magpie, folderErrors 0, encrypted, 6 files, Mac connected.
- 2026-10-26 (693e2a, weekly security review). Checked: govulncheck (Go 1.27.2) on lib/magpie,
  cmd/magpie-hubd, cmd/syncthing: GO-2026-6809 (crypto/x509 distrust list) reachable, fixed in Go
  1.27.3, now installed on Chicago and Frankfurt (old trees kept as ~/.local/go1.27.2); only other
  hit is GO-2026-5932 (x/crypto/openpgp, not imported). No new Syncthing or quic-go (v0.63.0)
  advisories. CI built the apps' engine with go.mod's Go 1.26.2: 14 reachable stdlib vulns
  (crypto/tls, x509, net/http). Hub: only 22000 tcp/udp public for Magpie (plus sshd, geph5-exit
  443, rpcbind 111: not Magpie), API on 127.0.0.1:8385, folder receiveencrypted, no plaintext
  outside *.syncthing-enc (spot-check: 26 MB file, 8.00 bits/byte), firewall check ok, devices =
  MacBook Pro + iPhone (both the owner's), invite used list 2 (10-19 05:32 Mac, 18:02 iPhone),
  journal: 1413 of 1485 failed TLS handshakes are Chicago's port probe, the rest scattered
  scanners (max 10 per address in a week). Found the hub forcing Syncthing usage reporting on at
  every start (rc version = "candidate"; urAccepted 3); the egress firewall blocked all 16 tries.
  GitHub: exactly the 8 secrets; Magpie workflows fully SHA-pinned (unpinned ones are upstream's,
  disabled or guarded to syncthing); no secrets in the tree or new files. Code review of
  7ff713976..HEAD (subagent, findings checked here): see below and the three new tasks in 6.
  Fixed (aa6895477): builds that can't upgrade don't force usage reporting, and hubd turns it off on
  hubs that had it (TestUsageReportingOff; startHub checks every hub starts with it off); remove
  replaces the invite key before deleting the device and admit reads the key after the pending
  list, so a failed remove can't leave a removed device able to rejoin
  (TestRemoveKeepsDeviceUntilKeyReplaced; both new tests failed on the old code); CI builds with
  the newest Go 1.27.x and runs govulncheck. Frankfurt --build-only 5/5 green (go1.27.3, rc
  version); CI run 40306089143 engine (with govulncheck) and mac green.
  Deployed c01edc54c274 after the owner allowed it (13:50 UTC): v2.1.7-rc.3.dev.106.gc01edc54-magpie,
  folderErrors 0, firewall ok, Mac connected; hubd logged "turning usage reporting off" once,
  config now urAccepted -1, no "always enabled" line since the restart.
  Open (tasks in 6): iPhone service ungated for invite(); invite key in a plaintext file in the
  engine folder; join links without confirmation. Not tested: anything on a real device.
- 2026-10-27 (b6acd1d7): upstream/main still 70b5bc78c, already merged; nothing to take. No engine
  or hub changes since the deployed c01edc54c (only TASKS), so no rebuild or redeploy. Frankfurt:
  magpie-hub and magpie-hubd active, /opt/magpie/current -> releases/c01edc54c274. Status (via
  `power run` once the owner allowed it, 21:52 UTC): v2.1.7-rc.3.dev.106.gc01edc54-magpie,
  folderErrors 0, encrypted, 6 files; Mac last seen 05:06 UTC, iPhone 10-22.
