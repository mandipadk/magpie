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

	// Removing the phone locks it out.
	if err := h.remove(phone.DeviceID()); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the phone to be cut off", func() bool { return !phone.Status().Connected })
	time.Sleep(4 * time.Second)
	if phone.Status().Accepted && phone.Status().Connected {
		t.Fatal("a removed device got back in")
	}
}
