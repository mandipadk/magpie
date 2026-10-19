// Copyright (C) 2026 The Magpie Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

package magpie

import (
	"testing"

	"github.com/syncthing/syncthing/lib/protocol"
)

// Names from other devices become paths in Finder and Files; only names
// this engine would make itself get in.
func TestValidFiles(t *testing.T) {
	var in []protocol.FileInfo
	for _, n := range []string{
		"Notes/today.md", "../escape", "Notes/../../escape", "/etc/passwd", "a/./b",
		"", ".", "..", "a\\..\\b", "Photos/", "Photos//x.jpg", "Résumé.pdf", ".hidden",
	} {
		in = append(in, protocol.FileInfo{Name: n})
	}
	var got []string
	for _, f := range validFiles(in) {
		got = append(got, f.Name)
	}
	want := []string{"Notes/today.md", "Résumé.pdf", ".hidden"}
	if len(got) != len(want) {
		t.Fatalf("kept %q, want %q", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("kept %q, want %q", got, want)
		}
	}
}
