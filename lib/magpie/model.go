// Copyright (C) 2026 The Magpie Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

package magpie

import (
	"log/slog"
	"sort"

	"github.com/syncthing/syncthing/lib/protocol"
)

// model receives the hub's messages (already decrypted by the protocol
// layer).
type model struct {
	e    *Engine
	conn protocol.Connection
}

func (m *model) ClusterConfig(_ protocol.Connection, cc *protocol.ClusterConfig) error {
	e := m.e
	for _, f := range cc.Folders {
		if f.ID == HistoryFolder(e.cfg.FolderID) {
			for _, d := range f.Devices {
				if d.ID == e.hubID {
					e.store.resetHistory(d.IndexID)
				}
			}
		}
	}
	for _, f := range cc.Folders {
		if f.ID != e.cfg.FolderID {
			continue
		}
		names := map[string]string{}
		var devices []DeviceInfo
		for _, d := range f.Devices {
			devices = append(devices, DeviceInfo{ID: d.ID.String(), Name: d.Name, Hub: d.ID == e.hubID})
			if d.ID == e.hubID {
				e.store.resetHub(d.IndexID)
				e.mu.Lock()
				e.hubMax = d.MaxSequence
				e.mu.Unlock()
			}
			if d.Name != "" {
				names[d.ID.Short().String()] = d.Name
			}
		}
		e.mu.Lock()
		e.names = names
		e.devices = devices
		e.mu.Unlock()
		e.setShared(true)
		return nil
	}
	// The hub doesn't share the folder with us (yet).
	e.setShared(false)
	return nil
}

func (m *model) Index(_ protocol.Connection, idx *protocol.Index) error {
	if idx.Folder == HistoryFolder(m.e.cfg.FolderID) {
		m.e.store.applyHistory(idx.Files, true, idx.LastSequence)
		return nil
	}
	if idx.Folder != m.e.cfg.FolderID {
		return nil
	}
	m.apply(idx.Files, true, idx.LastSequence)
	m.e.emit(Change{Kind: StatusChanged})
	return nil
}

func (m *model) IndexUpdate(_ protocol.Connection, up *protocol.IndexUpdate) error {
	if up.Folder == HistoryFolder(m.e.cfg.FolderID) {
		m.e.store.applyHistory(up.Files, false, up.LastSequence)
		return nil
	}
	if up.Folder != m.e.cfg.FolderID {
		return nil
	}
	m.apply(up.Files, false, up.LastSequence)
	return nil
}

func (m *model) apply(files []protocol.FileInfo, full bool, last int64) {
	e := m.e
	files = validFiles(files)
	prev := e.store.applyHub(files, full, last)
	changed := make([]string, 0, len(prev)+len(files))
	for name := range prev {
		changed = append(changed, name)
	}
	for _, f := range files {
		if _, ok := prev[f.Name]; !ok {
			changed = append(changed, f.Name)
		}
	}
	sort.Strings(changed)
	changed = dedupe(changed)

	var uploaded, conflicted []string
	for _, name := range changed {
		switch e.settle(name) {
		case settledUploaded:
			uploaded = append(uploaded, name)
		case settledConflict:
			conflicted = append(conflicted, name)
		}
	}
	if len(changed) > 0 {
		e.emit(Change{Kind: Changed, Paths: changed})
	}
	if len(uploaded) > 0 {
		e.emit(Change{Kind: Uploaded, Paths: uploaded})
	}
	if len(conflicted) > 0 {
		e.emit(Change{Kind: Conflicted, Paths: conflicted})
	}
}

func dedupe(s []string) []string {
	out := s[:0]
	for i, v := range s {
		if i == 0 || v != s[i-1] {
			out = append(out, v)
		}
	}
	return out
}

func (m *model) Request(_ protocol.Connection, req *protocol.Request) (protocol.RequestResponse, error) {
	e := m.e
	if req.Folder != e.cfg.FolderID {
		return nil, protocol.ErrGeneric
	}
	l, ok := e.store.localFile(req.Name)
	if !ok || !e.out.has(req.Name, l.Version) {
		return nil, protocol.ErrNoSuchFile
	}
	data, err := e.out.read(req.Name, l.Version, req.Offset, req.Size)
	if err != nil {
		slog.Debug("magpie: serving block", "name", req.Name, "err", err)
		return nil, protocol.ErrGeneric
	}
	return response(data), nil
}

func (m *model) DownloadProgress(protocol.Connection, *protocol.DownloadProgress) error { return nil }

func (m *model) Closed(_ protocol.Connection, err error) {
	slog.Debug("magpie: connection closed", "err", err)
}

type response []byte

func (r response) Data() []byte { return r }
func (r response) Close()       {}
func (r response) Wait()        {}
