# What Magpie's checks cover, and what they don't

Updated 2026-10-19. "CI e2e" is `apps/mac/e2e.sh` on a fresh GitHub macOS 15 runner, run on every
push; it installs the apps exactly as shipped (Developer ID, notarized). "Hub tests" are
`lib/magpie` and `cmd/magpie-hubd` against a real hub, run by CI and by `deploy.sh` on Frankfurt.

## Tested

| What | How |
| --- | --- |
| Fresh install from the page's link | CI e2e: Magpie.dmg downloaded as a browser would, Gatekeeper `source=Notarized Developer ID`, stapled, launches, asks to join |
| Sparkle update | CI e2e: build 25 (the last disk-image build) installed, joined, Magpie and its Finder extension running; Sparkle updates it from the candidate appcast (zip, EdDSA); the update only goes live after all of e2e passes (first green: run 39294365848, build 36) |
| Joining | CI e2e: a setup link from a test hub, Join in the app |
| Magpie in Finder | CI e2e: CloudStorage folder, Finder sidebar (screenshot) |
| Mac save shows on the "phone" | CI e2e: a file saved in Finder reaches a second device (cmd/magpie-phone) intact |
| Phone save shows on the Mac, on demand | CI e2e: arrives in Finder, opens intact |
| Conflict shown | CI e2e: an edit on each side; conflict copy in Finder, menu bar says a conflict needs you |
| Invites, strangers, reused and forged links | Hub tests |
| Removing a device locks it out | Hub tests: its own invites are refused; the Mac's invites keep working with the new key |
| Version history (list, preview, restore, deleted files) | Hub tests; no plaintext on the hub |

## Not tested

| What | Why |
| --- | --- |
| The iPhone app on a real iPhone | No iPhone here. The second device in CI e2e runs the iPhone app's engine, not the app or Files |
| Files app on iOS (browse, open, save) | Same; only the simulator screenshots of the Magpie app |
| The owner's own Mac after an update | CI's Mac is fresh each run and updates from build 25; the owner's Mac runs build 10 and froze mounting build 22's image |
| macOS's two extension processes sharing one engine's files | Seen in CI logs; no corruption seen, not tested for it |
| Sparkle's in-app flow (the "Install and Relaunch" window) | CI drives Sparkle's own command-line tool with the same appcast, key and installer |
| Gatekeeper's first-launch question | It's the system's dialog; CI checks Gatekeeper's verdict and removes the quarantine flag |
| Finder's "Magpie is not enabled" bar | macOS asks once per Mac; CI switches it on with pluginkit (the same setting) |
| Version History… in Finder's menu, the history window | Screenshot tests with sample data only |
| Removing a device from the page | The endpoint and the hub's `remove` are tested; not clicked on the live page (it would remove the owner's Mac) |
| Push nudges | Not built |
| Mounting a Magpie disk image while Magpie runs | Not repeated on purpose: it froze the owner's Mac. Updates no longer use disk images |
