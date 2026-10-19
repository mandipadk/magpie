// Copyright (C) 2026 The Magpie Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

package magpie

import (
	"reflect"
	"testing"
)

func TestChangeLog(t *testing.T) {
	c := newChangeLog()
	c.keep = 4
	a0 := c.anchor()
	c.add([]string{"a", "b"})
	got, a1, ok := c.since(a0)
	if !ok || !reflect.DeepEqual(got, []string{"a", "b"}) {
		t.Fatalf("since start: %v %v", got, ok)
	}
	if got, _, ok := c.since(a1); !ok || len(got) != 0 {
		t.Fatalf("nothing new: %v %v", got, ok)
	}
	c.add([]string{"a", "c"})
	if got, _, ok := c.since(a1); !ok || !reflect.DeepEqual(got, []string{"a", "c"}) {
		t.Fatalf("since a1: %v %v", got, ok)
	}
	c.add([]string{"d", "e", "f"}) // a0's changes fall out of the log
	if _, _, ok := c.since(a0); ok {
		t.Fatal("a too-old anchor was accepted")
	}
	if _, _, ok := c.since("other-run:1"); ok {
		t.Fatal("an anchor from another run was accepted")
	}
	if _, _, ok := c.since("garbage"); ok {
		t.Fatal("a garbage anchor was accepted")
	}
}
