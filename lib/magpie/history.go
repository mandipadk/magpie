// Copyright (C) 2026 The Magpie Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

package magpie

// Version history. The hub keeps every replaced or deleted file's encrypted
// copy (Syncthing's staggered versioning) in its own directory, and shares
// that directory with devices as a second, send-only folder. To the hub these
// are opaque files: each is the encrypted blocks of one version followed by a
// trailer holding its encrypted FileInfo and that trailer's length. A device
// with the password finds a file's versions by its encrypted name, reads the
// trailer to learn the real name and block list, and decrypts the blocks.
// Nothing new is needed on the wire, and the hub still can't read anything.

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"path"
	"sort"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"

	"github.com/syncthing/syncthing/internal/gen/bep"
	"github.com/syncthing/syncthing/lib/protocol"
)

// HistoryFolder is the ID of the hub's history folder for a Magpie folder.
func HistoryFolder(folderID string) string { return folderID + "-history" }

// versionTimeFormat is how the hub's versioner tags a version, in the hub's
// local time: UTC on Frankfurt (and TZ=UTC in the tests).
const versionTimeFormat = "20060102-150405"

// OldVersion is one old version of a file, kept by the hub.
type OldVersion struct {
	// ID names the version on the hub; pass it to FetchVersion or Restore.
	ID         string
	Path       string
	Size       int64
	Modified   time.Time
	ModifiedBy string
	// Kept is when the hub put this version aside (it was replaced or
	// deleted then).
	Kept time.Time
}

// ErrNoHistory means the hub hasn't shared its history folder with us.
var ErrNoHistory = errors.New("magpie: the server has no history for this device yet")

func (e *Engine) folderKey() *[32]byte {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.fkey == nil {
		e.fkey = e.keyGen.KeyFromPassword(e.cfg.FolderID, e.cfg.Password)
	}
	return e.fkey
}

// splitVersionName splits a history file name into the encrypted name of
// the file it belongs to and when it was kept. Encrypted names have no
// extension, so the versioner's tag is always at the end.
func splitVersionName(name string) (string, time.Time, bool) {
	i := strings.LastIndexByte(name, '~')
	if i < 0 {
		return "", time.Time{}, false
	}
	t, err := time.ParseInLocation(versionTimeFormat, name[i+1:], time.UTC)
	if err != nil {
		return "", time.Time{}, false
	}
	return name[:i], t, true
}

// Versions lists the hub's old versions of name, newest first.
func (e *Engine) Versions(ctx context.Context, name string) ([]OldVersion, error) {
	name = clean(name)
	enc := protocol.EncryptName(name, e.folderKey())
	var out []OldVersion
	for _, h := range e.store.historyNames() {
		base, kept, ok := splitVersionName(h)
		if !ok || base != enc {
			continue
		}
		v, err := e.versionInfo(ctx, h, kept)
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Kept.After(out[j].Kept) })
	return out, nil
}

// Deleted lists files that are gone from the folder but whose last version
// the hub still keeps, most recently deleted first.
func (e *Engine) Deleted(ctx context.Context) ([]OldVersion, error) {
	latest := map[string]OldVersion{}
	key := e.folderKey()
	for _, h := range e.store.historyNames() {
		base, kept, ok := splitVersionName(h)
		if !ok {
			continue
		}
		real, err := protocol.DecryptName(base, key)
		if err != nil {
			continue // not ours to read
		}
		if f, ok := e.store.current(real); ok && !f.IsDeleted() {
			continue
		}
		if prev, ok := latest[real]; ok && !kept.After(prev.Kept) {
			continue
		}
		latest[real] = OldVersion{ID: h, Path: real, Kept: kept}
	}
	out := make([]OldVersion, 0, len(latest))
	for _, v := range latest {
		full, err := e.versionInfo(ctx, v.ID, v.Kept)
		if err != nil {
			return nil, err
		}
		out = append(out, full)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Kept.After(out[j].Kept) })
	return out, nil
}

// versionInfo reads a version's trailer, fetching only the blocks at the end
// of the file that hold it. Results are cached; a version never changes.
func (e *Engine) versionInfo(ctx context.Context, id string, kept time.Time) (OldVersion, error) {
	e.mu.Lock()
	if v, ok := e.versionCache[id]; ok {
		e.mu.Unlock()
		return v, nil
	}
	e.mu.Unlock()

	_, real, err := e.versionTrailer(ctx, id)
	if err != nil {
		return OldVersion{}, err
	}
	v := OldVersion{
		ID:         id,
		Path:       real.Name,
		Size:       real.Size,
		Modified:   time.Unix(real.ModifiedS, int64(real.ModifiedNs)),
		ModifiedBy: e.deviceName(real.ModifiedBy),
		Kept:       kept,
	}
	e.mu.Lock()
	if e.versionCache == nil {
		e.versionCache = map[string]OldVersion{}
	}
	e.versionCache[id] = v
	e.mu.Unlock()
	return v, nil
}

// versionTrailer returns a version's encrypted FileInfo (as the hub stored
// it) and its decryption.
func (e *Engine) versionTrailer(ctx context.Context, id string) (protocol.FileInfo, protocol.FileInfo, error) {
	h, ok := e.store.historyFile(id)
	if !ok {
		return protocol.FileInfo{}, protocol.FileInfo{}, ErrNotFound
	}
	folder := HistoryFolder(e.cfg.FolderID)
	// Fetch blocks from the end until they cover the trailer.
	var tail []byte
	need := 4
	for i := len(h.Blocks) - 1; i >= 0 && len(tail) < need; i-- {
		data, err := e.requestBlock(ctx, folder, id, i, h.Blocks[i])
		if err != nil {
			return protocol.FileInfo{}, protocol.FileInfo{}, err
		}
		tail = append(data, tail...)
		if need == 4 && len(tail) >= 4 {
			need = int(binary.BigEndian.Uint32(tail[len(tail)-4:])) + 4
			if int64(need) > h.Size {
				return protocol.FileInfo{}, protocol.FileInfo{}, fmt.Errorf("magpie: version %s has a bad trailer", id)
			}
		}
	}
	if len(tail) < need {
		return protocol.FileInfo{}, protocol.FileInfo{}, fmt.Errorf("magpie: version %s is short", id)
	}
	return e.decryptTrailer(tail[len(tail)-need : len(tail)-4])
}

func (e *Engine) decryptTrailer(bs []byte) (protocol.FileInfo, protocol.FileInfo, error) {
	var wire bep.FileInfo
	if err := proto.Unmarshal(bs, &wire); err != nil {
		return protocol.FileInfo{}, protocol.FileInfo{}, fmt.Errorf("magpie: reading a version: %w", err)
	}
	enc := protocol.FileInfoFromWire(&wire)
	real, err := protocol.DecryptFileInfo(e.keyGen, enc, e.folderKey())
	if err != nil {
		return protocol.FileInfo{}, protocol.FileInfo{}, fmt.Errorf("magpie: decrypting a version: %w", err)
	}
	if len(real.Blocks) != len(enc.Blocks) {
		return protocol.FileInfo{}, protocol.FileInfo{}, errors.New("magpie: a version's block lists don't match")
	}
	return enc, real, nil
}

// FetchVersion writes the content of version id to dst: it downloads the
// encrypted file (every block checked against the hub's hash), then
// decrypts it block by block (every block checked against the real hash).
func (e *Engine) FetchVersion(ctx context.Context, id, dst string) (OldVersion, error) {
	h, ok := e.store.historyFile(id)
	if !ok {
		return OldVersion{}, ErrNotFound
	}
	_, kept, _ := splitVersionName(id)
	folder := HistoryFolder(e.cfg.FolderID)

	raw, err := os.CreateTemp(e.cfg.DataDir, "version-*")
	if err != nil {
		return OldVersion{}, err
	}
	defer os.Remove(raw.Name())
	defer raw.Close()
	for i, b := range h.Blocks {
		data, err := e.requestBlock(ctx, folder, id, i, b)
		if err != nil {
			return OldVersion{}, err
		}
		if _, err := raw.WriteAt(data, b.Offset); err != nil {
			return OldVersion{}, err
		}
	}

	var lenBuf [4]byte
	if _, err := raw.ReadAt(lenBuf[:], h.Size-4); err != nil {
		return OldVersion{}, err
	}
	n := int64(binary.BigEndian.Uint32(lenBuf[:]))
	if n+4 > h.Size {
		return OldVersion{}, fmt.Errorf("magpie: version %s has a bad trailer", id)
	}
	trailer := make([]byte, n)
	if _, err := raw.ReadAt(trailer, h.Size-4-n); err != nil {
		return OldVersion{}, err
	}
	enc, real, err := e.decryptTrailer(trailer)
	if err != nil {
		return OldVersion{}, err
	}

	fileKey := e.keyGen.FileKey(real.Name, e.folderKey())
	tmp := dst + ".magpie-part"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return OldVersion{}, err
	}
	fail := func(err error) (OldVersion, error) {
		out.Close()
		os.Remove(tmp)
		return OldVersion{}, err
	}
	if err := out.Truncate(real.Size); err != nil {
		return fail(err)
	}
	for i, rb := range real.Blocks {
		eb := enc.Blocks[i]
		cipher := make([]byte, eb.Size)
		if _, err := raw.ReadAt(cipher, eb.Offset); err != nil {
			return fail(err)
		}
		plain, err := protocol.DecryptBytes(cipher, fileKey)
		if err != nil {
			return fail(fmt.Errorf("magpie: decrypting block %d of a version: %w", i, err))
		}
		// Blocks under 1 KiB are padded before they're encrypted.
		if len(plain) < rb.Size {
			return fail(fmt.Errorf("magpie: block %d of a version is short", i))
		}
		plain = plain[:rb.Size]
		if sum := sha256.Sum256(plain); !bytes.Equal(sum[:], rb.Hash) {
			return fail(fmt.Errorf("magpie: block %d of a version failed its hash check", i))
		}
		if _, err := out.WriteAt(plain, rb.Offset); err != nil {
			return fail(err)
		}
	}
	if err := out.Close(); err != nil {
		return fail(err)
	}
	if err := os.Rename(tmp, dst); err != nil {
		return OldVersion{}, err
	}
	modified := time.Unix(real.ModifiedS, int64(real.ModifiedNs))
	_ = os.Chtimes(dst, time.Now(), modified)
	return OldVersion{
		ID: id, Path: real.Name, Size: real.Size, Modified: modified,
		ModifiedBy: e.deviceName(real.ModifiedBy), Kept: kept,
	}, nil
}

// Restore puts version id back as the current content of its file, as a
// new edit (so the version it replaces goes into history in turn). A
// deleted file comes back where it was.
func (e *Engine) Restore(ctx context.Context, id string) (Entry, error) {
	tmp, err := os.CreateTemp(e.cfg.DataDir, "restore-*")
	if err != nil {
		return Entry{}, err
	}
	tmp.Close()
	defer os.Remove(tmp.Name())
	v, err := e.FetchVersion(ctx, id, tmp.Name())
	if err != nil {
		return Entry{}, err
	}
	base := ""
	if cur, ok := e.store.current(v.Path); ok && !cur.IsDeleted() {
		base = cur.Version.String()
	}
	return e.Put(ctx, v.Path, tmp.Name(), base)
}

// RestoreCopy puts version id beside its file as "Name (restored 19 Oct
// 14.02).ext", leaving the current file as it is.
func (e *Engine) RestoreCopy(ctx context.Context, id string) (Entry, error) {
	tmp, err := os.CreateTemp(e.cfg.DataDir, "restore-*")
	if err != nil {
		return Entry{}, err
	}
	tmp.Close()
	defer os.Remove(tmp.Name())
	v, err := e.FetchVersion(ctx, id, tmp.Name())
	if err != nil {
		return Entry{}, err
	}
	ext := path.Ext(v.Path)
	stem := strings.TrimSuffix(v.Path, ext)
	name := fmt.Sprintf("%s (restored %s)%s", stem, v.Modified.Local().Format("2 Jan 15.04"), ext)
	for i := 2; ; i++ {
		if f, ok := e.store.current(name); !ok || f.IsDeleted() {
			break
		}
		name = fmt.Sprintf("%s (restored %s, %d)%s", stem, v.Modified.Local().Format("2 Jan 15.04"), i, ext)
	}
	return e.Put(ctx, name, tmp.Name(), "")
}
