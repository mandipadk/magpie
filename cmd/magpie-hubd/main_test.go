// Copyright (C) 2026 The Magpie Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

package main

// Runs a real hub set up by `magpie-hubd init` and checks who gets in.
// Needs MAGPIE_SYNCTHING (see lib/magpie/hub_test.go).

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/syncthing/syncthing/lib/magpie"
)

func freePort(t *testing.T) int {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func startHub(t *testing.T) (*hub, string) {
	bin := os.Getenv("MAGPIE_SYNCTHING")
	if bin == "" {
		t.Skip("MAGPIE_SYNCTHING not set")
	}
	home := t.TempDir()
	addr := fmt.Sprintf("127.0.0.1:%d", freePort(t))
	h := &hub{home: home}
	if err := h.init(bin, addr); err != nil {
		t.Fatal(err)
	}
	// a free GUI port for parallel runs
	cfg, _ := os.ReadFile(filepath.Join(home, "config.xml"))
	cfg = bytes.Replace(cfg, []byte("127.0.0.1:8385"), []byte(fmt.Sprintf("127.0.0.1:%d", freePort(t))), 1)
	cfg = bytes.ReplaceAll(cfg, []byte("0.0.0.0:"), []byte("127.0.0.1:"))
	_ = os.WriteFile(filepath.Join(home, "config.xml"), cfg, 0o600)

	cmd := exec.Command(bin, "serve", "--home", home, "--no-browser", "--no-restart")
	cmd.Env = append(os.Environ(), "STNOUPGRADE=1")
	logf, _ := os.Create(filepath.Join(home, "hub.log"))
	cmd.Stdout, cmd.Stderr = logf, logf
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _, _ = cmd.Process.Wait() })
	waitFor(t, "hub API", func() bool { _, err := h.status(); return err == nil })

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go func() {
		for ctx.Err() == nil {
			_ = h.admit()
			_ = h.ensureHistory()
			time.Sleep(200 * time.Millisecond)
		}
	}()
	return h, addr
}

func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func join(t *testing.T, link, name string) *magpie.Engine {
	in, err := magpie.ParseInvite(link)
	if err != nil {
		t.Fatal(err)
	}
	e, err := magpie.New(magpie.ConfigFromInvite(in, t.TempDir(), name))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go e.Run(ctx)
	return e
}

func ready(e *magpie.Engine) bool { s := e.Status(); return s.Connected && s.Accepted && s.Ready }

// The first device joins with the server's link; the second with an invite
// from the first; the two then share files. Strangers, reused invites and
// forged invites stay out.
func TestJoinByInvite(t *testing.T) {
	h, _ := startHub(t)

	setup, err := h.setupLink("")
	if err != nil {
		t.Fatal(err)
	}
	mac := join(t, setup, "MacBook Air")
	waitFor(t, "the Mac to be admitted", func() bool { return ready(mac) })

	// The same server link a second time: refused.
	again := join(t, setup, "Someone else")
	time.Sleep(4 * time.Second)
	if again.Status().Accepted {
		t.Fatal("a used setup link let a second device in")
	}

	// A forged token: refused.
	forged, _ := magpie.ParseInvite(setup)
	forged.Token = magpie.NewToken([]byte("not the hub's key, not the hub's key"), time.Now())
	stranger := join(t, forged.Link(), "Stranger")
	time.Sleep(3 * time.Second)
	if stranger.Status().Accepted {
		t.Fatal("a forged invite let a device in")
	}

	invite, err := mac.Invite()
	if err != nil {
		t.Fatal(err)
	}
	phone := join(t, invite, "iPhone")
	waitFor(t, "the iPhone to be admitted", func() bool { return ready(phone) })

	src := filepath.Join(t.TempDir(), "f")
	_ = os.WriteFile(src, []byte("hello from the Mac"), 0o600)
	if _, err := mac.Put(context.Background(), "hello.txt", src, ""); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the phone to see the file", func() bool { _, err := phone.Stat("hello.txt"); return err == nil })
	dst := filepath.Join(t.TempDir(), "d")
	if _, err := phone.Fetch(context.Background(), "hello.txt", dst, nil); err != nil {
		t.Fatal(err)
	}
	if bs, _ := os.ReadFile(dst); string(bs) != "hello from the Mac" {
		t.Fatalf("phone read %q", bs)
	}

	s, err := h.status()
	if err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, d := range s.Devices {
		names[d.Name] = true
	}
	if !names["MacBook Air"] || !names["iPhone"] || names["Stranger"] || names["Someone else"] || len(s.Devices) != 2 {
		t.Fatalf("hub devices: %+v", s.Devices)
	}

	// Both devices can read the hub's history.
	waitFor(t, "both devices on the history folder", func() bool {
		var hist map[string]any
		if err := h.api("GET", "/rest/config/folders/magpie-history", nil, &hist); err != nil {
			return false
		}
		return lenAny(hist["devices"]) == 3 // the hub and the two devices
	})

	// An edit puts the old version aside, and the page counts it.
	cur, err := mac.Stat("hello.txt")
	if err != nil {
		t.Fatal(err)
	}
	_ = os.WriteFile(src, []byte("hello again from the Mac"), 0o600)
	if _, err := mac.Put(context.Background(), "hello.txt", src, cur.Version); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the hub to count the old version", func() bool {
		s, err := h.status()
		return err == nil && s.HistoryN == 1 && s.History > 0 && time.Since(s.HistoryAt) < time.Hour
	})

	// Removing the phone locks it out.
	if err := h.remove(phone.DeviceID()); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the phone to be cut off", func() bool { return !phone.Status().Connected })
	time.Sleep(4 * time.Second)
	if phone.Status().Accepted && phone.Status().Connected {
		t.Fatal("a removed device got back in")
	}

	// The removed phone still holds the old invite key: an invite it makes
	// (say, for a new device ID on the same stolen phone) is refused.
	stolen, err := phone.Invite()
	if err != nil {
		t.Fatal(err)
	}
	thief := join(t, stolen, "Thief")
	time.Sleep(4 * time.Second)
	if thief.Status().Accepted {
		t.Fatal("an invite from a removed device let a new device in")
	}

	// The Mac learns the new key from the hub, and its invites still work.
	newKey, _ := h.inviteKey()
	waitFor(t, "the Mac to learn the new invite key", func() bool {
		link, err := mac.Invite()
		in, _ := magpie.ParseInvite(link)
		return err == nil && bytes.Equal(in.Key, newKey)
	})
	invite, err = mac.Invite()
	if err != nil {
		t.Fatal(err)
	}
	ipad := join(t, invite, "iPad")
	waitFor(t, "the iPad to be admitted with the new key", func() bool { return ready(ipad) })
	if s, _ := h.status(); s.HistoryN != 1 {
		t.Fatalf("the published key counted as history: %d versions", s.HistoryN)
	}
}

// A hub set up before history existed gets it: versions move to the history
// directory and the folder is shared with every device of the main folder.
func TestHistoryForOlderHubs(t *testing.T) {
	h, _ := startHub(t)
	// a version kept before history existed
	oldVersion := filepath.Join("A.syncthing-enc", "BC", "DEFGHIJ~20261019-053953")
	oldPath := filepath.Join(h.home, "folder", ".stversions", oldVersion)
	_ = os.MkdirAll(filepath.Dir(oldPath), 0o700)
	if err := os.WriteFile(oldPath, []byte("ciphertext"), 0o600); err != nil {
		t.Fatal(err)
	}
	var hist map[string]any
	if err := h.api("DELETE", "/rest/config/folders/magpie-history", nil, nil); err != nil {
		t.Fatal(err)
	}
	var folder map[string]any
	if err := h.api("GET", "/rest/config/folders/magpie", nil, &folder); err != nil {
		t.Fatal(err)
	}
	folder["versioning"].(map[string]any)["fsPath"] = ""
	if err := h.api("PUT", "/rest/config/folders/magpie", folder, nil); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "history set up again", func() bool {
		if err := h.ensureHistory(); err != nil {
			return false
		}
		if err := h.api("GET", "/rest/config/folders/magpie-history", nil, &hist); err != nil {
			return false
		}
		_ = h.api("GET", "/rest/config/folders/magpie", nil, &folder)
		return hist["type"] == "sendonly" && hist["path"] == h.historyDir() &&
			folder["versioning"].(map[string]any)["fsPath"] == h.historyDir()
	})
	if bs, err := os.ReadFile(filepath.Join(h.historyDir(), oldVersion)); err != nil || string(bs) != "ciphertext" {
		t.Fatalf("the old version didn't move into history: %v", err)
	}
	if _, err := os.Stat(oldPath); err == nil {
		t.Fatal("the old version is still in .stversions")
	}
	waitFor(t, "the hub to count it", func() bool {
		s, err := h.status()
		return err == nil && s.HistoryN == 1 && s.HistoryAt.Equal(time.Date(2026, 10, 19, 5, 39, 53, 0, time.UTC))
	})
}
