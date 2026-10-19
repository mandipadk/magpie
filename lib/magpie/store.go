// Copyright (C) 2026 The Magpie Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

package magpie

import (
	"bytes"
	"encoding/gob"
	"os"
	"path"
	"sort"
	"strings"
	"sync"

	"github.com/syncthing/syncthing/lib/protocol"
)

// store is the engine's small database: the hub's decrypted index, our own
// announced index and what is pinned. It is kept in memory
// and written whole on every change; a folder of tens of thousands of files
// is a few megabytes.
type store struct {
	file string

	mu   sync.Mutex
	data storeData
}

type storeData struct {
	HubIndexID protocol.IndexID
	HubSeq     int64
	Hub        map[string]protocol.FileInfo

	LocalIndexID protocol.IndexID
	LocalSeq     int64
	Local        map[string]protocol.FileInfo

	// Pinned paths (files or directories) are kept downloaded.
	Pinned map[string]bool
	// Joined is set once the hub has accepted this device.
	Joined bool
}

func openStore(file string) (*store, error) {
	s := &store{file: file}
	bs, err := os.ReadFile(file)
	switch {
	case err == nil:
		if err := gob.NewDecoder(bytes.NewReader(bs)).Decode(&s.data); err != nil {
			return nil, err
		}
	case os.IsNotExist(err):
	default:
		return nil, err
	}
	if s.data.Hub == nil {
		s.data.Hub = map[string]protocol.FileInfo{}
	}
	if s.data.Local == nil {
		s.data.Local = map[string]protocol.FileInfo{}
	}
	if s.data.Pinned == nil {
		s.data.Pinned = map[string]bool{}
	}
	if s.data.LocalIndexID == 0 {
		s.data.LocalIndexID = protocol.NewIndexID()
	}
	return s, s.saveLocked()
}

// saveLocked writes the store atomically. Callers hold mu (or own s).
func (s *store) saveLocked() error {
	var buf bytes.Buffer
	if err := gob.NewEncoder(&buf).Encode(&s.data); err != nil {
		return err
	}
	tmp := s.file + ".tmp"
	if err := os.WriteFile(tmp, buf.Bytes(), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.file)
}

func (s *store) hubIndexState() (protocol.IndexID, int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.data.HubIndexID, s.data.HubSeq
}

func (s *store) localIndexState() (protocol.IndexID, int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.data.LocalIndexID, s.data.LocalSeq
}

// resetHub forgets the hub's index when the hub says it started a new one.
func (s *store) resetHub(id protocol.IndexID) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.data.HubIndexID == id {
		return
	}
	s.data.HubIndexID = id
	s.data.HubSeq = 0
	s.data.Hub = map[string]protocol.FileInfo{}
	_ = s.saveLocked()
}

// applyHub records files from the hub. A full index replaces what we had.
// It returns the previous entries of the files that changed.
func (s *store) applyHub(files []protocol.FileInfo, full bool, last int64) map[string]protocol.FileInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	prev := map[string]protocol.FileInfo{}
	if full {
		old := s.data.Hub
		s.data.Hub = make(map[string]protocol.FileInfo, len(files))
		for name, f := range old {
			prev[name] = f
		}
	}
	for _, f := range files {
		f.Blocks = append([]protocol.BlockInfo(nil), f.Blocks...)
		if p, ok := s.data.Hub[f.Name]; ok {
			prev[f.Name] = p
		}
		s.data.Hub[f.Name] = f
	}
	// Unchanged entries in a full index aren't changes.
	for name, p := range prev {
		if n, ok := s.data.Hub[name]; ok && n.Version.Equal(p.Version) && n.Deleted == p.Deleted {
			delete(prev, name)
		}
	}
	if last > s.data.HubSeq {
		s.data.HubSeq = last
	}
	_ = s.saveLocked()
	return prev
}

func (s *store) hubFile(name string) (protocol.FileInfo, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	f, ok := s.data.Hub[name]
	return f, ok
}

func (s *store) localFile(name string) (protocol.FileInfo, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	f, ok := s.data.Local[name]
	return f, ok
}

// announce adds a file to our own index with the next sequence number.
func (s *store) announce(f protocol.FileInfo) protocol.FileInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.data.LocalSeq++
	f.Sequence = s.data.LocalSeq
	s.data.Local[f.Name] = f
	_ = s.saveLocked()
	return f
}

func (s *store) localFiles() ([]protocol.FileInfo, int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	fs := make([]protocol.FileInfo, 0, len(s.data.Local))
	for _, f := range s.data.Local {
		fs = append(fs, f)
	}
	sort.Slice(fs, func(a, b int) bool { return fs[a].Sequence < fs[b].Sequence })
	return fs, s.data.LocalSeq
}

// current is the newest thing we know about name: our own edit while the hub
// hasn't got it yet, otherwise the hub's.
func (s *store) current(name string) (protocol.FileInfo, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.currentLocked(name)
}

func (s *store) currentLocked(name string) (protocol.FileInfo, bool) {
	h, hok := s.data.Hub[name]
	l, lok := s.data.Local[name]
	switch {
	case lok && (!hok || l.Version.Compare(h.Version) == protocol.Greater):
		return l, true
	case hok:
		return h, true
	}
	return protocol.FileInfo{}, false
}

// children lists what is directly inside dir ("" is the root), not deleted.
func (s *store) children(dir string) []protocol.FileInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	seen := map[string]bool{}
	var out []protocol.FileInfo
	add := func(name string) {
		if seen[name] || path.Dir(name) != dirOrDot(dir) {
			return
		}
		seen[name] = true
		if f, ok := s.currentLocked(name); ok && !f.IsDeleted() && !f.IsInvalid() {
			out = append(out, f)
		}
	}
	for name := range s.data.Hub {
		add(name)
	}
	for name := range s.data.Local {
		add(name)
	}
	sort.Slice(out, func(a, b int) bool { return strings.ToLower(out[a].Name) < strings.ToLower(out[b].Name) })
	return out
}

// descendants lists every live entry under dir, deepest first.
func (s *store) descendants(dir string) []protocol.FileInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	prefix := dir + "/"
	seen := map[string]bool{}
	var out []protocol.FileInfo
	for _, m := range []map[string]protocol.FileInfo{s.data.Hub, s.data.Local} {
		for name := range m {
			if seen[name] || !strings.HasPrefix(name, prefix) {
				continue
			}
			seen[name] = true
			if f, ok := s.currentLocked(name); ok && !f.IsDeleted() {
				out = append(out, f)
			}
		}
	}
	sort.Slice(out, func(a, b int) bool { return strings.Count(out[a].Name, "/") > strings.Count(out[b].Name, "/") })
	return out
}

func dirOrDot(dir string) string {
	if dir == "" {
		return "."
	}
	return dir
}

func (s *store) isJoined() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.data.Joined
}

func (s *store) setJoined() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.data.Joined {
		s.data.Joined = true
		_ = s.saveLocked()
	}
}

func (s *store) setPinned(name string, on bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if on {
		s.data.Pinned[name] = true
	} else {
		delete(s.data.Pinned, name)
	}
	_ = s.saveLocked()
}

// pinnedCovers reports whether name or one of its parents is pinned.
func (s *store) pinnedCovers(name string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for p := name; p != "." && p != "/" && p != ""; p = path.Dir(p) {
		if s.data.Pinned[p] {
			return true
		}
	}
	return false
}

func (s *store) pinned() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]string, 0, len(s.data.Pinned))
	for p := range s.data.Pinned {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// stats counts live files and their bytes.
func (s *store) stats() (files int, bytes int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for name := range s.data.Hub {
		if f, ok := s.currentLocked(name); ok && !f.IsDeleted() && !f.IsDirectory() {
			files++
			bytes += f.Size
		}
	}
	return files, bytes
}
