// Copyright (C) 2026 The Magpie Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

package magpie

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"os"
	"path/filepath"
	"time"
)

// InviteKeyFile is where the hub publishes the current invite key, in the
// history folder it shares with the devices still in Magpie. Removing a
// device makes a new key, so the removed device's copy no longer makes
// invites the hub accepts, and only the remaining devices learn the new one.
const InviteKeyFile = ".magpie/invite-key"

// savedKeyFile keeps the newest key this device has heard of.
const savedKeyFile = "invite-key"

// inviteKey returns the invite key to make links with: the hub's published
// one when it can be read, else the last one saved, else the one this
// device joined with.
func (e *Engine) inviteKey(ctx context.Context) []byte {
	saved := filepath.Join(e.cfg.DataDir, savedKeyFile)
	have, _ := os.ReadFile(saved)
	e.mu.Lock()
	online := e.conn != nil
	e.mu.Unlock()
	// Offline, the saved key is the best there is; the hub tells the
	// device about a newer one as soon as it reconnects.
	if f, ok := e.store.historyFile(InviteKeyFile); ok && online && len(f.Blocks) == 1 && f.Size <= 128 {
		sum := sha256.Sum256(have)
		if !bytes.Equal(sum[:], f.Blocks[0].Hash) {
			if data, err := e.requestBlock(ctx, HistoryFolder(e.cfg.FolderID), InviteKeyFile, 0, f.Blocks[0]); err == nil {
				if writeFileAtomic(saved, data) == nil {
					have = data
				}
			}
		}
	}
	if key, err := base64.RawURLEncoding.DecodeString(string(bytes.TrimSpace(have))); err == nil && len(key) >= 16 {
		return key
	}
	return e.cfg.InviteKey
}

func writeFileAtomic(name string, data []byte) error {
	tmp := name + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, name)
}

// inviteKeyTimeout bounds how long making an invite waits for the hub.
const inviteKeyTimeout = 20 * time.Second
