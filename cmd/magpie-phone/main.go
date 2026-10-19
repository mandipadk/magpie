// Copyright (C) 2026 The Magpie Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

// Command magpie-phone is a second Magpie device for end-to-end runs
// (apps/mac/e2e.sh): the engine the iPhone app runs, driven from a shell,
// one step at a time, with its state kept in --dir between steps.
//
//	magpie-phone join <link>                 join with an invite from the Mac
//	magpie-phone get <path> <dst>            wait for path, then download it
//	magpie-phone put <path> <src>            upload src as path
//	magpie-phone put-offline <path> <src>    edit path from the version this
//	                                         device last saw, before it hears
//	                                         of newer ones (a conflict, on purpose)
//	magpie-phone conflicts                   the conflicts this device sees, JSON
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime/debug"
	"time"

	"github.com/syncthing/syncthing/lib/magpie"
)

func main() {
	log.SetFlags(0)
	debug.SetMemoryLimit(24 << 20) // as lib/magpie/mobile sets it for the apps
	dir := flag.String("dir", "phone", "this device's state")
	timeout := flag.Duration("timeout", 2*time.Minute, "how long to wait for each step")
	flag.Parse()
	args := flag.Args()
	if len(args) == 0 {
		log.Fatal("usage: magpie-phone [--dir D] join|get|put-offline|conflicts ...")
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	cfgFile := filepath.Join(*dir, "config.json")

	if args[0] == "join" && len(args) == 2 {
		in, err := magpie.ParseInvite(args[1])
		check(err)
		check(os.MkdirAll(*dir, 0o700))
		cfg := magpie.ConfigFromInvite(in, filepath.Join(*dir, "data"), "iPhone (e2e)")
		// as the iPhone app does: the key derived once, kept with the config
		cfg.FolderKey = magpie.DeriveFolderKey(cfg.FolderID, cfg.Password)
		bs, _ := json.Marshal(cfg)
		check(os.WriteFile(cfgFile, bs, 0o600))
		e := open(cfgFile)
		run(ctx, e)
		wait(ctx, "the hub to admit this device", func() bool { s := e.Status(); return s.Connected && s.Accepted && s.Ready })
		fmt.Println("joined as", e.DeviceID())
		return
	}

	e := open(cfgFile)
	switch {
	case args[0] == "get" && len(args) == 3:
		run(ctx, e)
		wait(ctx, args[1]+" to arrive", func() bool { _, err := e.Stat(args[1]); return err == nil })
		en, err := e.Fetch(ctx, args[1], args[2], nil)
		check(err)
		fmt.Printf("got %s, %d bytes, saved by %s\n", en.Path, en.Size, en.ModifiedBy)
	case args[0] == "put" && len(args) == 3:
		run(ctx, e)
		wait(ctx, "the hub", func() bool { return e.Status().Ready })
		base := ""
		if cur, err := e.Stat(args[1]); err == nil {
			base = cur.Version
		}
		_, err := e.Put(ctx, args[1], args[2], base)
		check(err)
		wait(ctx, "the upload", func() bool { en, err := e.Stat(args[1]); return err == nil && en.OnHub && e.Status().UploadsLeft == 0 })
		fmt.Println("uploaded", args[1])
	case args[0] == "put-offline" && len(args) == 3:
		cur, err := e.Stat(args[1])
		check(err)
		_, err = e.Put(ctx, args[1], args[2], cur.Version)
		check(err)
		run(ctx, e)
		wait(ctx, "the edit to reach the hub", func() bool { en, err := e.Stat(args[1]); return err == nil && en.OnHub && e.Status().UploadsLeft == 0 })
		wait(ctx, "the conflict to show here", func() bool { return len(e.Conflicts()) > 0 })
		fmt.Println("edited", args[1], "against the version it last saw")
	case args[0] == "conflicts":
		run(ctx, e)
		wait(ctx, "the hub", func() bool { return e.Status().Ready })
		bs, _ := json.Marshal(e.Conflicts())
		fmt.Println(string(bs))
	default:
		log.Fatal("magpie-phone: unknown step")
	}
}

func open(cfgFile string) *magpie.Engine {
	bs, err := os.ReadFile(cfgFile)
	check(err)
	var cfg magpie.Config
	check(json.Unmarshal(bs, &cfg))
	e, err := magpie.New(cfg)
	check(err)
	return e
}

func run(ctx context.Context, e *magpie.Engine) { go e.Run(ctx) }

func wait(ctx context.Context, what string, ok func() bool) {
	for !ok() {
		select {
		case <-ctx.Done():
			check(errors.New("timed out waiting for " + what))
		case <-time.After(250 * time.Millisecond):
		}
	}
}

func check(err error) {
	if err != nil {
		log.Fatal("magpie-phone: ", err)
	}
}
