// Copyright (C) 2026 The Syncthing Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

package protocol

// Magpie's trusted devices find a file's old versions on the encrypted hub by
// its encrypted name, and name what they find there. Kept in this file so
// upstream merges don't touch it.

// EncryptName returns name as an untrusted device stores it under folderKey.
func EncryptName(name string, folderKey *[keySize]byte) string {
	return encryptName(name, folderKey)
}

// DecryptName reverses EncryptName.
func DecryptName(name string, folderKey *[keySize]byte) (string, error) {
	return decryptName(name, folderKey)
}

// FolderKeySize is the length of a folder key.
const FolderKeySize = keySize

// SetFolderKey seeds the cache with a folder key derived earlier, so a
// process with little memory (an iOS File Provider extension) never runs
// scrypt, which takes 32 MiB at once.
func (g *KeyGenerator) SetFolderKey(folderID, password string, key *[keySize]byte) {
	g.mut.Lock()
	defer g.mut.Unlock()
	g.folderKeys.Add(folderKeyCacheKey{folderID, password}, key)
}
