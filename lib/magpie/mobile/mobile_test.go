// Copyright (C) 2026 The Magpie Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

package mobile

import (
	"bytes"
	"encoding/json"
	"testing"

	"github.com/syncthing/syncthing/lib/magpie"
)

// A kept config without the folder key gets it, derived as Syncthing does;
// one that has it is left alone.
func TestPrepareConfig(t *testing.T) {
	old := `{"hubID":"h","hubAddr":"a:1","folderID":"magpie","password":"pw","deviceName":"iPhone","inviteKey":"AAAA"}`
	got, err := PrepareConfig(old)
	if err != nil {
		t.Fatal(err)
	}
	var c config
	if err := json.Unmarshal([]byte(got), &c); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(c.FolderKey, magpie.DeriveFolderKey("magpie", "pw")) || c.Password != "pw" || c.DeviceName != "iPhone" {
		t.Fatalf("prepared config: %s", got)
	}
	again, _ := PrepareConfig(got)
	if again != got {
		t.Fatal("a prepared config changed")
	}
}
