// Copyright (C) 2026 The Magpie Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

package magpie

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
	"syscall"
)

// ErrBusy means another process has this device's engine open: a second
// copy of the File Provider extension (an update, or a copy of Magpie on a
// mounted disk image) must not write the same index and outbox at once.
var ErrBusy = errors.New("magpie: another copy of Magpie is using this device's files")

var (
	locksMu sync.Mutex
	locks   = map[string]*os.File{} // held for the life of the process
)

// lockDataDir takes an exclusive, non-blocking lock on dir for this process.
// A process may open the engine more than once; other processes are refused.
func lockDataDir(dir string) error {
	name := filepath.Join(dir, "lock")
	locksMu.Lock()
	defer locksMu.Unlock()
	if _, ok := locks[name]; ok {
		return nil
	}
	f, err := os.OpenFile(name, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return ErrBusy
		}
		return err
	}
	locks[name] = f
	return nil
}
