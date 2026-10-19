// Copyright (C) 2026 The Magpie Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

// Package mobile is the engine as the Mac and iPhone apps see it, built with
// gomobile into Magpie.xcframework. gomobile passes only simple types, so
// lists and records cross as JSON.
package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/magpie"
)

// Listener hears about changes. Kinds: 0 changed, 1 uploaded, 2 conflicted,
// 3 status. paths is a JSON array.
type Listener interface {
	OnChange(kind int, paths string)
}

// Progress hears how far a download is.
type Progress interface {
	OnProgress(done, total int64)
}

// Engine wraps magpie.Engine.
type Engine struct {
	e      *magpie.Engine
	mu     sync.Mutex
	cancel context.CancelFunc
	done   chan struct{}
}

// config is what the apps keep (in the keychain): everything Open needs.
type config struct {
	HubID      string `json:"hubID"`
	HubAddr    string `json:"hubAddr"`
	FolderID   string `json:"folderID"`
	Password   string `json:"password"`
	DeviceName string `json:"deviceName"`
	JoinToken  string `json:"joinToken,omitempty"`
	InviteKey  []byte `json:"inviteKey"`
}

// ConfigFromLink turns a magpie1: link into the config to keep. The first
// device's link (from the server) has no password; one is made here.
func ConfigFromLink(link, deviceName string) (string, error) {
	in, err := magpie.ParseInvite(link)
	if err != nil {
		return "", err
	}
	c := magpie.ConfigFromInvite(in, "", deviceName)
	bs, err := json.Marshal(config{c.HubID, c.HubAddr, c.FolderID, c.Password, c.DeviceName, c.JoinToken, c.InviteKey})
	return string(bs), err
}

// Open opens the engine with a kept config and its state directory.
func Open(configJSON, dataDir string) (*Engine, error) {
	var c config
	if err := json.Unmarshal([]byte(configJSON), &c); err != nil {
		return nil, err
	}
	e, err := magpie.New(magpie.Config{
		DataDir:    filepath.Clean(dataDir),
		HubID:      c.HubID,
		HubAddr:    c.HubAddr,
		FolderID:   c.FolderID,
		Password:   c.Password,
		DeviceName: c.DeviceName,
		JoinToken:  c.JoinToken,
		InviteKey:  c.InviteKey,
	})
	if err != nil {
		return nil, err
	}
	return &Engine{e: e}, nil
}

// DeviceID is this device's ID.
func (m *Engine) DeviceID() string { return m.e.DeviceID() }

// Start connects and keeps connected until Stop.
func (m *Engine) Start() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.cancel != nil {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	m.cancel, m.done = cancel, make(chan struct{})
	go func() { m.e.Run(ctx); close(m.done) }()
}

// Stop disconnects.
func (m *Engine) Stop() {
	m.mu.Lock()
	cancel, done := m.cancel, m.done
	m.cancel = nil
	m.mu.Unlock()
	if cancel != nil {
		cancel()
		<-done
	}
}

// SetListener registers l for changes.
func (m *Engine) SetListener(l Listener) {
	m.e.OnChange(func(c magpie.Change) {
		bs, _ := json.Marshal(c.Paths)
		if c.Paths == nil {
			bs = []byte("[]")
		}
		l.OnChange(int(c.Kind), string(bs))
	})
}

// WaitReady waits up to timeoutMs for the server's list; it reports whether
// it arrived.
func (m *Engine) WaitReady(timeoutMs int64) bool {
	deadline := time.Now().Add(time.Duration(timeoutMs) * time.Millisecond)
	for {
		if m.e.Status().Ready {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func js(v any) string {
	bs, _ := json.Marshal(v)
	return string(bs)
}

// List returns the entries in dir as JSON.
func (m *Engine) List(dir string) string { return js(m.e.List(dir)) }

// Stat returns one entry as JSON.
func (m *Engine) Stat(path string) (string, error) {
	en, err := m.e.Stat(path)
	if err != nil {
		return "", mapErr(err)
	}
	return js(en), nil
}

func ctxFor(timeoutMs int64) (context.Context, context.CancelFunc) {
	if timeoutMs <= 0 {
		timeoutMs = 10 * 60 * 1000
	}
	return context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
}

// Fetch downloads path to dst and returns its entry.
func (m *Engine) Fetch(path, dst string, timeoutMs int64, p Progress) (string, error) {
	ctx, cancel := ctxFor(timeoutMs)
	defer cancel()
	var cb func(done, total int64)
	if p != nil {
		cb = p.OnProgress
	}
	en, err := m.e.Fetch(ctx, path, dst, cb)
	if err != nil {
		return "", mapErr(err)
	}
	return js(en), nil
}

// Put stores src as path; base is the version the edit started from.
func (m *Engine) Put(path, src, base string) (string, error) {
	ctx, cancel := ctxFor(0)
	defer cancel()
	en, err := m.e.Put(ctx, path, src, base)
	if err != nil {
		return "", mapErr(err)
	}
	return js(en), nil
}

// Mkdir makes a folder.
func (m *Engine) Mkdir(path string) (string, error) {
	ctx, cancel := ctxFor(0)
	defer cancel()
	en, err := m.e.Mkdir(ctx, path)
	if err != nil {
		return "", mapErr(err)
	}
	return js(en), nil
}

// Delete removes path.
func (m *Engine) Delete(path, base string) error {
	ctx, cancel := ctxFor(0)
	defer cancel()
	return mapErr(m.e.Delete(ctx, path, base))
}

// Rename moves path to newPath.
func (m *Engine) Rename(path, newPath, base string) (string, error) {
	ctx, cancel := ctxFor(0)
	defer cancel()
	en, err := m.e.Rename(ctx, path, newPath, base)
	if err != nil {
		return "", mapErr(err)
	}
	return js(en), nil
}

// Status returns the engine's status as JSON.
func (m *Engine) Status() string { return js(m.e.Status()) }

// Conflicts lists conflicts as JSON.
func (m *Engine) Conflicts() string {
	cs := m.e.Conflicts()
	if cs == nil {
		cs = []magpie.Conflict{}
	}
	return js(cs)
}

// Resolve settles the conflict whose copy is copyPath: keep 0 both,
// 1 the original, 2 the copy.
func (m *Engine) Resolve(copyPath string, keep int) error {
	for _, c := range m.e.Conflicts() {
		if c.Copy == copyPath {
			ctx, cancel := ctxFor(0)
			defer cancel()
			return mapErr(m.e.Resolve(ctx, c, magpie.Keep(keep)))
		}
	}
	return errors.New("that conflict is already settled")
}

// Invite makes a single-use link for a new device.
func (m *Engine) Invite() (string, error) { return m.e.Invite() }

// Pause stops syncing; Resume starts it again.
func (m *Engine) Pause()  { m.e.Pause() }
func (m *Engine) Resume() { m.e.Resume() }

// Pin keeps path downloaded on this device (or stops).
func (m *Engine) Pin(path string, on bool) { m.e.Pin(path, on) }

// Pinned reports whether path is kept downloaded.
func (m *Engine) Pinned(path string) bool { return m.e.Pinned(path) }

// PinnedPaths lists kept paths as JSON.
func (m *Engine) PinnedPaths() string {
	ps := m.e.PinnedPaths()
	if ps == nil {
		ps = []string{}
	}
	return js(ps)
}

// Errors the apps tell apart, by message prefix.
const (
	ErrCodeOffline  = "offline:"
	ErrCodeNotFound = "notfound:"
	ErrCodeChanged  = "changed:"
	ErrCodePaused   = "paused:"
)

func mapErr(err error) error {
	switch {
	case err == nil:
		return nil
	case errors.Is(err, magpie.ErrOffline):
		return errors.New(ErrCodeOffline + " " + err.Error())
	case errors.Is(err, magpie.ErrNotFound):
		return errors.New(ErrCodeNotFound + " " + err.Error())
	case errors.Is(err, magpie.ErrChanged):
		return errors.New(ErrCodeChanged + " " + err.Error())
	case errors.Is(err, magpie.ErrPaused):
		return errors.New(ErrCodePaused + " " + err.Error())
	}
	return err
}

// Anchor is the change log's position, for ChangesSince.
func (m *Engine) Anchor() string { return m.e.Anchor() }

// ChangesSince returns {"paths": [...], "next": anchor, "ok": bool}; ok
// false means list everything again.
func (m *Engine) ChangesSince(anchor string) string {
	paths, next, ok := m.e.ChangesSince(anchor)
	if paths == nil {
		paths = []string{}
	}
	return js(struct {
		Paths []string `json:"paths"`
		Next  string   `json:"next"`
		OK    bool     `json:"ok"`
	}{paths, next, ok})
}

// Devices lists the devices sharing the folder as JSON.
func (m *Engine) Devices() string { return js(m.e.Devices()) }
