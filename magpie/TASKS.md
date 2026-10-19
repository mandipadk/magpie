# Magpie tasks (want 3a54493a)

Magpie is the owner's own iCloud Drive: a Syncthing fork (branch `magpie`, upstream remote
`upstream`) with an always-on encrypted node in Frankfurt and Mac and iPhone apps that show it in
Finder and Files. Design notes: magpie/README.md.

## Asked of the owner (once)
- [ ] Repo public or private (ask-me, 2026-10-19)
- [ ] Oracle ingress TCP+UDP 22000 (errand ffcbaa)
- [ ] Copy Developer ID + App Store Connect key into the magpie repo secrets (power secret github)
- [ ] App Store Connect app record for Magpie (errand, after bundle IDs exist)
- [ ] Root on Frankfurt: magpie user, systemd unit, firewall 22000 (power sudo, one list)

## 1. Server
- [x] Fork syncthing at frankfurt:~/code/magpie, branch `magpie`; Go 1.27 in ~/.local/go
- [ ] magpie-server: syncthing as user `magpie`, GUI on 127.0.0.1 only, listen 22000, no global
      discovery/relays/usage reporting, folders receive-encrypted, staggered versioning
- [ ] Enrollment: one-time invites minted by enrolled devices (HMAC with the invite key), checked by
      the server on the Hello; revoke a device
- [ ] Prove: server cannot read files (only encrypted names/blocks on disk), versions kept

## 2. Engine (Go, shared by Mac and iPhone; gomobile)
- [ ] magpie core: one BEP connection to the hub, decrypted index in a local db, fetch on demand
      (blocks verified), upload changes, conflict copies, pins (keep offline), events
- [ ] Go tests: two clients + real server: save on A shows on B; concurrent edit gives a conflict copy
      on both sides, nothing lost; delete then restore from version history

## 3. Mac app
- [ ] Mockups (Halation, Mac conventions) reviewed by the critic
- [ ] File Provider (replicated) extension: Magpie in the Finder sidebar, download on demand, keep downloaded
- [ ] Menu bar item: status, pause, conflicts; Settings window; add device (QR/link)
- [ ] Developer ID, notarized .dmg, Sparkle from build 1 (appcast on the release), page with download
- [ ] CI on macOS runner: engine tests against the live server, screenshots, check the stapled dmg

## 4. iPhone app
- [ ] Mockups; File Provider extension in Files (open, save, keep offline); app: status, add device
- [ ] TestFlight

## 5. Duties
- [ ] Daily upstream sync (rebase, build, test, deploy or roll back)
- [ ] Weekly security review

## 6. Make it ours (propose, then build)
