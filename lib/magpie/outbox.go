// Copyright (C) 2026 The Magpie Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

package magpie

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"sync"

	"github.com/syncthing/syncthing/lib/protocol"
)

// outbox keeps the content of this device's edits until the hub has them.
// The hub pulls blocks from here when it sees our index; once its own index
// shows the same version, the copy is dropped.
type outbox struct {
	dir string
	mu  sync.Mutex
}

func openOutbox(dir string) (*outbox, error) {
	return &outbox{dir: dir}, os.MkdirAll(dir, 0o700)
}

// key names the stored copy of one version of one file.
func (o *outbox) key(name string, v protocol.Vector) string {
	h := sha256.Sum256([]byte(name + "\x00" + v.String()))
	return filepath.Join(o.dir, hex.EncodeToString(h[:16]))
}

// put copies src into the outbox for (name, v).
func (o *outbox) put(name string, v protocol.Vector, src string) (string, error) {
	dst := o.key(name, v)
	in, err := os.Open(src)
	if err != nil {
		return "", err
	}
	defer in.Close()
	tmp := dst + ".tmp"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return "", err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return "", err
	}
	if err := out.Close(); err != nil {
		return "", err
	}
	return dst, os.Rename(tmp, dst)
}

func (o *outbox) has(name string, v protocol.Vector) bool {
	_, err := os.Stat(o.key(name, v))
	return err == nil
}

func (o *outbox) path(name string, v protocol.Vector) string { return o.key(name, v) }

func (o *outbox) read(name string, v protocol.Vector, offset int64, size int) ([]byte, error) {
	f, err := os.Open(o.key(name, v))
	if err != nil {
		return nil, err
	}
	defer f.Close()
	buf := make([]byte, size)
	n, err := f.ReadAt(buf, offset)
	if err != nil && err != io.EOF {
		return nil, err
	}
	return buf[:n], nil
}

func (o *outbox) drop(name string, v protocol.Vector) {
	_ = os.Remove(o.key(name, v))
}
