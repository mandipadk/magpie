// Copyright (C) 2026 The Magpie Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

package magpie

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// changeLog numbers every change so the system's file browsers can ask
// "what changed since anchor N". Anchors carry an epoch that is new each
// time the engine starts; an anchor from an earlier run is expired and the
// browser lists everything again.
type changeLog struct {
	mu    sync.Mutex
	epoch string
	seq   int64
	log   []logEntry // ascending seq, at most keep entries
	keep  int
}

type logEntry struct {
	seq  int64
	path string
}

func newChangeLog() *changeLog {
	var b [6]byte
	_, _ = rand.Read(b[:])
	return &changeLog{epoch: hex.EncodeToString(b[:]), keep: 20000}
}

func (c *changeLog) add(paths []string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, p := range paths {
		c.seq++
		c.log = append(c.log, logEntry{c.seq, p})
	}
	if over := len(c.log) - c.keep; over > 0 {
		c.log = append([]logEntry(nil), c.log[over:]...)
	}
}

// Anchor is the current position.
func (c *changeLog) anchor() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return fmt.Sprintf("%s:%d", c.epoch, c.seq)
}

// since returns the paths changed after anchor, and false if the anchor is
// too old or from another run.
func (c *changeLog) since(anchor string) ([]string, string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	cur := fmt.Sprintf("%s:%d", c.epoch, c.seq)
	epoch, n, ok := strings.Cut(anchor, ":")
	from, err := strconv.ParseInt(n, 10, 64)
	if !ok || err != nil || epoch != c.epoch || from > c.seq {
		return nil, cur, false
	}
	if from == c.seq {
		return []string{}, cur, true
	}
	if len(c.log) == 0 || c.log[0].seq > from+1 {
		return nil, cur, false
	}
	seen := map[string]bool{}
	var out []string
	i := sort.Search(len(c.log), func(i int) bool { return c.log[i].seq > from })
	for _, e := range c.log[i:] {
		if !seen[e.path] {
			seen[e.path] = true
			out = append(out, e.path)
		}
	}
	return out, cur, true
}

// Anchor is where the change log is now; pass it to ChangesSince later.
func (e *Engine) Anchor() string { return e.changes.anchor() }

// ChangesSince lists the paths (and their parent folders) changed after
// anchor. ok is false if the anchor is no longer usable; list everything.
func (e *Engine) ChangesSince(anchor string) (paths []string, next string, ok bool) {
	return e.changes.since(anchor)
}

// DeviceInfo is a device sharing the folder, as the server describes it.
type DeviceInfo struct {
	ID      string
	Name    string
	ThisOne bool
	Hub     bool
}

// Devices lists the devices the server shares the folder with.
func (e *Engine) Devices() []DeviceInfo {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := []DeviceInfo{{ID: e.myID.String(), Name: e.cfg.DeviceName, ThisOne: true}}
	for _, d := range e.devices {
		if d.ID == e.myID.String() {
			continue
		}
		out = append(out, d)
	}
	return out
}
