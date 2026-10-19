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
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/syncthing/syncthing/lib/protocol"
)

// ErrChanged means the file changed elsewhere since the caller last saw it.
var ErrChanged = errors.New("magpie: the file changed on another device")

// Entry is a file or directory as the apps see it.
type Entry struct {
	Path     string
	Dir      bool
	Size     int64
	Modified time.Time
	// Version identifies this exact version; pass it back as the base of an
	// edit or delete.
	Version string
	// OnHub is false while this device's edit is still being sent.
	OnHub bool
	// ModifiedBy is the name of the device that made this version, when known.
	ModifiedBy string
}

func (e *Engine) entry(f protocol.FileInfo) Entry {
	h, hok := e.store.hubFile(f.Name)
	return Entry{
		Path:       f.Name,
		Dir:        f.IsDirectory(),
		Size:       f.Size,
		Modified:   time.Unix(f.ModifiedS, int64(f.ModifiedNs)),
		Version:    f.Version.String(),
		OnHub:      hok && h.Version.Equal(f.Version),
		ModifiedBy: e.deviceName(f.ModifiedBy),
	}
}

// List returns what is directly inside dir ("" for the top).
func (e *Engine) List(dir string) []Entry {
	fs := e.store.children(clean(dir))
	out := make([]Entry, 0, len(fs))
	for _, f := range fs {
		out = append(out, e.entry(f))
	}
	return out
}

// Stat returns one entry.
func (e *Engine) Stat(name string) (Entry, error) {
	f, ok := e.store.current(clean(name))
	if !ok || f.IsDeleted() {
		return Entry{}, ErrNotFound
	}
	return e.entry(f), nil
}

// Fetch writes the current content of name to dst, fetching it from the hub
// block by block and checking every block's hash.
func (e *Engine) Fetch(ctx context.Context, name, dst string, progress func(done, total int64)) (Entry, error) {
	name = clean(name)
	f, ok := e.store.current(name)
	if !ok || f.IsDeleted() {
		return Entry{}, ErrNotFound
	}
	if f.IsDirectory() {
		return Entry{}, fmt.Errorf("magpie: %s is a folder", name)
	}
	tmp := dst + ".magpie-part"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return Entry{}, err
	}
	fail := func(err error) (Entry, error) {
		out.Close()
		os.Remove(tmp)
		return Entry{}, err
	}

	// Our own edit that hasn't reached the hub yet is right here.
	if e.out.has(name, f.Version) {
		if l, ok := e.store.localFile(name); ok && l.Version.Equal(f.Version) {
			in, err := os.ReadFile(e.out.path(name, f.Version))
			if err != nil {
				return fail(err)
			}
			if _, err := out.Write(in); err != nil {
				return fail(err)
			}
			if err := out.Close(); err != nil {
				return fail(err)
			}
			return e.entry(f), os.Rename(tmp, dst)
		}
	}

	if err := out.Truncate(f.Size); err != nil {
		return fail(err)
	}
	var done int64
	for i, b := range f.Blocks {
		data, err := e.requestBlock(ctx, e.cfg.FolderID, name, i, b)
		if err != nil {
			return fail(err)
		}
		if _, err := out.WriteAt(data, b.Offset); err != nil {
			return fail(err)
		}
		done += int64(b.Size)
		if progress != nil {
			progress(done, f.Size)
		}
	}
	if err := out.Sync(); err != nil {
		return fail(err)
	}
	if err := out.Close(); err != nil {
		return fail(err)
	}
	if err := os.Rename(tmp, dst); err != nil {
		return Entry{}, err
	}
	_ = os.Chtimes(dst, time.Now(), time.Unix(f.ModifiedS, int64(f.ModifiedNs)))
	return e.entry(f), nil
}

func (e *Engine) requestBlock(ctx context.Context, folder, name string, i int, b protocol.BlockInfo) ([]byte, error) {
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		wctx, cancel := context.WithTimeout(ctx, 30*time.Second)
		conn, err := e.currentConn(wctx)
		cancel()
		if err != nil {
			return nil, err
		}
		rctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
		data, err := conn.Request(rctx, &protocol.Request{
			Folder:  folder,
			Name:    name,
			Offset:  b.Offset,
			Size:    b.Size,
			Hash:    b.Hash,
			BlockNo: i,
		})
		cancel()
		if err == nil {
			sum := sha256.Sum256(data)
			if bytes.Equal(sum[:], b.Hash) {
				return data, nil
			}
			err = fmt.Errorf("magpie: block %d of %s failed its hash check", i, name)
		}
		lastErr = err
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
	}
	return nil, lastErr
}

// Put stores src as the new content of name. base is the Version the edit
// started from ("" for a new file). If the file changed elsewhere since
// base, nothing is overwritten: the edit is saved as a conflict copy beside
// it, and the copy's entry is returned.
func (e *Engine) Put(ctx context.Context, name, src, base string) (Entry, error) {
	name = clean(name)
	if name == "" {
		return Entry{}, errors.New("magpie: no name")
	}
	target := name
	if cur, ok := e.store.current(name); ok && !cur.IsDeleted() {
		if base == "" || cur.Version.String() != base {
			if fileSame(cur, src) {
				return e.entry(cur), nil
			}
			target = e.conflictName(name, time.Now())
		}
	}
	return e.write(ctx, target, src)
}

// write announces src as the next version of name, whatever is there.
func (e *Engine) write(ctx context.Context, name, src string) (Entry, error) {
	if err := e.mkdirAll(ctx, path.Dir(name)); err != nil {
		return Entry{}, err
	}
	fd, err := os.Open(src)
	if err != nil {
		return Entry{}, err
	}
	st, err := fd.Stat()
	if err != nil {
		fd.Close()
		return Entry{}, err
	}
	bs := protocol.BlockSize(st.Size())
	blocks, err := hashBlocks(ctx, fd, bs)
	fd.Close()
	if err != nil {
		return Entry{}, err
	}
	var prev protocol.Vector
	if cur, ok := e.store.current(name); ok {
		prev = cur.Version
	}
	v := prev.Update(e.myID.Short())
	if _, err := e.out.put(name, v, src); err != nil {
		return Entry{}, err
	}
	mod := st.ModTime()
	f := protocol.FileInfo{
		Name:         name,
		Type:         protocol.FileInfoTypeFile,
		Size:         st.Size(),
		ModifiedS:    mod.Unix(),
		ModifiedNs:   int32(mod.Nanosecond()),
		ModifiedBy:   e.myID.Short(),
		Version:      v,
		Blocks:       blocks,
		BlocksHash:   protocol.BlocksHash(blocks),
		Permissions:  0o644,
		RawBlockSize: int32(bs),
	}
	f = e.store.announce(f)
	e.sendUpdate(ctx, f)
	e.emit(Change{Kind: Changed, Paths: []string{name}})
	return e.entry(f), nil
}

// fileSame reports whether src has exactly the content of f, so saving it
// again is not an edit.
func fileSame(f protocol.FileInfo, src string) bool {
	fd, err := os.Open(src)
	if err != nil {
		return false
	}
	defer fd.Close()
	st, err := fd.Stat()
	if err != nil || st.Size() != f.Size || f.IsDirectory() {
		return false
	}
	blocks, err := hashBlocks(context.Background(), fd, f.BlockSize())
	if err != nil {
		return false
	}
	return bytes.Equal(protocol.BlocksHash(blocks), protocol.BlocksHash(f.Blocks))
}

// Mkdir makes a folder (and its parents).
func (e *Engine) Mkdir(ctx context.Context, name string) (Entry, error) {
	name = clean(name)
	if err := e.mkdirAll(ctx, name); err != nil {
		return Entry{}, err
	}
	return e.Stat(name)
}

func (e *Engine) mkdirAll(ctx context.Context, name string) error {
	if name == "" || name == "." {
		return nil
	}
	if cur, ok := e.store.current(name); ok && !cur.IsDeleted() {
		if cur.IsDirectory() {
			return nil
		}
		return fmt.Errorf("magpie: %s is a file", name)
	}
	if err := e.mkdirAll(ctx, path.Dir(name)); err != nil {
		return err
	}
	var prev protocol.Vector
	if cur, ok := e.store.current(name); ok {
		prev = cur.Version
	}
	now := time.Now()
	f := e.store.announce(protocol.FileInfo{
		Name:        name,
		Type:        protocol.FileInfoTypeDirectory,
		ModifiedS:   now.Unix(),
		ModifiedNs:  int32(now.Nanosecond()),
		ModifiedBy:  e.myID.Short(),
		Version:     prev.Update(e.myID.Short()),
		Permissions: 0o755,
	})
	e.sendUpdate(ctx, f)
	e.emit(Change{Kind: Changed, Paths: []string{name}})
	return nil
}

// Delete removes name (a folder with everything in it). base is the Version
// the caller saw; if a file changed since, it is not deleted and ErrChanged
// is returned. Deleted files stay in the server's history.
func (e *Engine) Delete(ctx context.Context, name, base string) error {
	name = clean(name)
	cur, ok := e.store.current(name)
	if !ok || cur.IsDeleted() {
		return nil
	}
	if base != "" && !cur.IsDirectory() && cur.Version.String() != base {
		return ErrChanged
	}
	var gone []string
	if cur.IsDirectory() {
		for _, d := range e.store.descendants(name) {
			e.tombstone(ctx, d)
			gone = append(gone, d.Name)
		}
	}
	e.tombstone(ctx, cur)
	gone = append(gone, name)
	e.emit(Change{Kind: Changed, Paths: gone})
	return nil
}

func (e *Engine) tombstone(ctx context.Context, cur protocol.FileInfo) {
	now := time.Now()
	f := e.store.announce(protocol.FileInfo{
		Name:        cur.Name,
		Type:        cur.Type,
		ModifiedS:   now.Unix(),
		ModifiedNs:  int32(now.Nanosecond()),
		ModifiedBy:  e.myID.Short(),
		Version:     cur.Version.Update(e.myID.Short()),
		Deleted:     true,
		Permissions: cur.Permissions,
	})
	e.sendUpdate(ctx, f)
}

// Rename moves name to newName. The server can't move encrypted files (each
// name has its own key), so file content is fetched and sent again.
func (e *Engine) Rename(ctx context.Context, name, newName, base string) (Entry, error) {
	name, newName = clean(name), clean(newName)
	cur, ok := e.store.current(name)
	if !ok || cur.IsDeleted() {
		return Entry{}, ErrNotFound
	}
	if base != "" && !cur.IsDirectory() && cur.Version.String() != base {
		return Entry{}, ErrChanged
	}
	if _, ok := e.store.current(newName); ok {
		if f, _ := e.store.current(newName); !f.IsDeleted() {
			return Entry{}, fmt.Errorf("magpie: %s already exists", newName)
		}
	}
	tmpDir, err := os.MkdirTemp(e.cfg.DataDir, "rename-")
	if err != nil {
		return Entry{}, err
	}
	defer os.RemoveAll(tmpDir)

	move := func(f protocol.FileInfo, to string) error {
		if f.IsDirectory() {
			return e.mkdirAll(ctx, to)
		}
		tmp := filepath.Join(tmpDir, "f")
		if _, err := e.Fetch(ctx, f.Name, tmp, nil); err != nil {
			return err
		}
		_, err := e.write(ctx, to, tmp)
		return err
	}
	if err := move(cur, newName); err != nil {
		return Entry{}, err
	}
	if cur.IsDirectory() {
		ds := e.store.descendants(name)
		// shallowest first when creating
		for i := len(ds) - 1; i >= 0; i-- {
			if err := move(ds[i], newName+strings.TrimPrefix(ds[i].Name, name)); err != nil {
				return Entry{}, err
			}
		}
	}
	if err := e.Delete(ctx, name, ""); err != nil {
		return Entry{}, err
	}
	return e.Stat(newName)
}

func (e *Engine) sendUpdate(ctx context.Context, f protocol.FileInfo) {
	e.mu.Lock()
	conn := e.conn
	e.mu.Unlock()
	if conn == nil {
		return // sent with the full index on the next connection
	}
	_ = conn.IndexUpdate(ctx, &protocol.IndexUpdate{
		Folder:       e.cfg.FolderID,
		Files:        []protocol.FileInfo{f},
		LastSequence: f.Sequence,
		PrevSequence: f.Sequence - 1,
	})
}

type settled int

const (
	settledNothing settled = iota
	settledUploaded
	settledConflict
)

// settle looks at name after the hub's index changed, for an edit of ours
// that is still waiting in the outbox.
func (e *Engine) settle(name string) settled {
	l, ok := e.store.localFile(name)
	if !ok || l.IsDeleted() || l.IsDirectory() || !e.out.has(name, l.Version) {
		return settledNothing
	}
	h, ok := e.store.hubFile(name)
	if !ok {
		return settledNothing
	}
	switch l.Version.Compare(h.Version) {
	case protocol.Equal:
		e.out.drop(name, l.Version)
		return settledUploaded
	case protocol.Lesser:
		// Someone edited after ours landed; ours is in the history.
		e.out.drop(name, l.Version)
		return settledNothing
	case protocol.ConcurrentLesser, protocol.ConcurrentGreater:
		// Another device's edit won. Keep ours beside it.
		copyName := e.conflictName(name, time.Unix(l.ModifiedS, 0))
		src := e.out.path(name, l.Version)
		if _, err := e.write(context.Background(), copyName, src); err != nil {
			return settledNothing
		}
		e.out.drop(name, l.Version)
		return settledConflict
	}
	return settledNothing
}

// conflictName is Syncthing's own conflict naming, so every Syncthing
// device recognises it: "Budget.sync-conflict-20261019-140500-ABCDEFG.numbers".
func (e *Engine) conflictName(name string, t time.Time) string {
	ext := path.Ext(name)
	base := strings.TrimSuffix(name, ext)
	return fmt.Sprintf("%s.sync-conflict-%s-%s%s", base, t.Format("20060102-150405"), e.myID.Short().String(), ext)
}

var conflictRe = regexp.MustCompile(`^(.*)\.sync-conflict-(\d{8}-\d{6})-([A-Z0-9]{7})(\.[^/]*)?$`)

// Conflict is a pair of versions waiting for the owner.
type Conflict struct {
	// Copy is the conflict copy; Original is the file it belongs to.
	Copy, Original string
	// CopyBy is the device whose edit lost, when known.
	CopyBy string
	When   time.Time
	// The two versions side by side, for choosing between them.
	CopyEntry, OriginalEntry Entry
}

// Conflicts lists every conflict copy in the folder, made on any device.
func (e *Engine) Conflicts() []Conflict {
	var out []Conflict
	var walk func(dir string)
	walk = func(dir string) {
		for _, f := range e.store.children(dir) {
			if f.IsDirectory() {
				walk(f.Name)
				continue
			}
			m := conflictRe.FindStringSubmatch(f.Name)
			if m == nil {
				continue
			}
			when, _ := time.ParseInLocation("20060102-150405", m[2], time.Local)
			c := Conflict{Copy: f.Name, Original: m[1] + m[4], CopyBy: e.nameOf(m[3]), When: when}
			c.CopyEntry, _ = e.Stat(c.Copy)
			c.OriginalEntry, _ = e.Stat(c.Original)
			out = append(out, c)
		}
	}
	walk("")
	return out
}

// Keep says how to settle a conflict.
type Keep int

const (
	// KeepBoth renames the copy to "Name (Device).ext" and keeps both.
	KeepBoth Keep = iota
	// KeepOriginal deletes the copy.
	KeepOriginal
	// KeepCopy puts the copy's content in place of the original.
	KeepCopy
)

// Resolve settles one conflict.
func (e *Engine) Resolve(ctx context.Context, c Conflict, keep Keep) error {
	switch keep {
	case KeepOriginal:
		return e.Delete(ctx, c.Copy, "")
	case KeepBoth:
		by := c.CopyBy
		if by == "" {
			by = "other device"
		}
		ext := path.Ext(c.Original)
		to := fmt.Sprintf("%s (%s)%s", strings.TrimSuffix(c.Original, ext), by, ext)
		for i := 2; ; i++ {
			if f, ok := e.store.current(to); !ok || f.IsDeleted() {
				break
			}
			to = fmt.Sprintf("%s (%s %d)%s", strings.TrimSuffix(c.Original, ext), by, i, ext)
		}
		_, err := e.Rename(ctx, c.Copy, to, "")
		return err
	case KeepCopy:
		tmpDir, err := os.MkdirTemp(e.cfg.DataDir, "resolve-")
		if err != nil {
			return err
		}
		defer os.RemoveAll(tmpDir)
		tmp := filepath.Join(tmpDir, "f")
		if _, err := e.Fetch(ctx, c.Copy, tmp, nil); err != nil {
			return err
		}
		if _, err := e.write(ctx, c.Original, tmp); err != nil {
			return err
		}
		return e.Delete(ctx, c.Copy, "")
	}
	return errors.New("magpie: unknown choice")
}

// Pin keeps name (and, for a folder, everything in it) downloaded on this
// device; the apps ask the system to fetch it and keep it current.
func (e *Engine) Pin(name string, on bool) {
	e.store.setPinned(clean(name), on)
	e.emit(Change{Kind: StatusChanged})
}

// Pinned reports whether name is kept downloaded (itself or a parent).
func (e *Engine) Pinned(name string) bool { return e.store.pinnedCovers(clean(name)) }

// PinnedPaths lists what is kept downloaded.
func (e *Engine) PinnedPaths() []string { return e.store.pinned() }

// Status is what the menu bar and the app show.
type Status struct {
	Connected bool
	// Accepted is false until the server shares the folder with this device.
	Accepted bool
	// Ready is true once the server's full list has arrived.
	Ready       bool
	Paused      bool
	Files       int
	Bytes       int64
	UploadsLeft int
	UploadBytes int64
	LastError   string
	DeviceID    string
}

// Status reports the engine's state.
func (e *Engine) Status() Status {
	e.mu.Lock()
	s := Status{
		Connected: e.conn != nil,
		Accepted:  e.shared,
		Ready:     false,
		Paused:    e.paused,
		DeviceID:  e.myID.String(),
	}
	if e.lastErr != nil && e.conn == nil {
		s.LastError = e.lastErr.Error()
	}
	hubMax := e.hubMax
	e.mu.Unlock()
	_, hubSeq := e.store.hubIndexState()
	s.Ready = s.Connected && s.Accepted && hubSeq >= hubMax
	s.Files, s.Bytes = e.store.stats()
	files, _ := e.store.localFiles()
	for _, f := range files {
		if !f.IsDeleted() && !f.IsDirectory() && e.out.has(f.Name, f.Version) {
			s.UploadsLeft++
			s.UploadBytes += f.Size
		}
	}
	return s
}

func (e *Engine) setShared(on bool) {
	if on {
		e.store.setJoined()
	}
	e.mu.Lock()
	e.shared = on
	e.mu.Unlock()
}

func (e *Engine) deviceName(id protocol.ShortID) string { return e.nameOf(id.String()) }

// nameOf maps a short device ID ("ABCDEFG") to the device's name, as the
// server lists them.
func (e *Engine) nameOf(short string) string {
	if short == e.myID.Short().String() {
		return e.cfg.DeviceName
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.names[short]
}

func clean(name string) string {
	name = strings.Trim(path.Clean("/"+strings.ReplaceAll(name, "\\", "/")), "/")
	if name == "." {
		return ""
	}
	return name
}

// hashBlocks splits r into blocks of size bs and hashes each, as Syncthing's
// scanner does (without its file system layer, which the iPhone doesn't need).
func hashBlocks(ctx context.Context, r io.Reader, bs int) ([]protocol.BlockInfo, error) {
	var blocks []protocol.BlockInfo
	buf := make([]byte, bs)
	var offset int64
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		n, err := io.ReadFull(r, buf)
		if n > 0 {
			sum := sha256.Sum256(buf[:n])
			blocks = append(blocks, protocol.BlockInfo{Hash: sum[:], Offset: offset, Size: n})
			offset += int64(n)
		}
		if err == io.EOF || err == io.ErrUnexpectedEOF {
			break
		}
		if err != nil {
			return nil, err
		}
	}
	if len(blocks) == 0 {
		// an empty file has one empty block, as the scanner makes it
		sum := sha256.Sum256(nil)
		blocks = append(blocks, protocol.BlockInfo{Hash: sum[:]})
	}
	return blocks, nil
}
