// Copyright (C) 2026 The Magpie Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

package magpie

// These tests run two engines (a "Mac" and an "iPhone") against a real
// Syncthing hub holding the folder receive-encrypted, the way the Frankfurt
// server does. Set MAGPIE_SYNCTHING to a syncthing binary to run them:
//
//	go run build.go -no-upgrade build syncthing
//	MAGPIE_SYNCTHING=$PWD/syncthing go test ./lib/magpie/ -run Hub -v

import (
	"bytes"
	"context"
	"fmt"
	"io/fs"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/syncthing/syncthing/lib/protocol"
)

const testPassword = "correct horse battery staple"

type hub struct {
	id, addr, home string
	cmd            *exec.Cmd
}

func freePort(t *testing.T) int {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

// startHub runs syncthing with the folder "magpie" receive-encrypted and
// shared with the given devices.
func startHub(t *testing.T, devices map[string]string) *hub {
	bin := os.Getenv("MAGPIE_SYNCTHING")
	if bin == "" {
		t.Skip("MAGPIE_SYNCTHING not set")
	}
	home := t.TempDir()
	if out, err := exec.Command(bin, "generate", "--home", home).CombinedOutput(); err != nil {
		t.Fatalf("generate: %v\n%s", err, out)
	}
	out, err := exec.Command(bin, "device-id", "--home", home).Output()
	if err != nil {
		t.Fatal(err)
	}
	id := strings.TrimSpace(string(out))
	port := freePort(t)
	h := &hub{id: id, addr: fmt.Sprintf("127.0.0.1:%d", port), home: home}

	var folderDevs, devs strings.Builder
	fmt.Fprintf(&folderDevs, `<device id="%s"></device>`, id)
	fmt.Fprintf(&devs, `<device id="%s" name="Frankfurt"><address>dynamic</address></device>`, id)
	for devID, name := range devices {
		fmt.Fprintf(&folderDevs, `<device id="%s"></device>`, devID)
		fmt.Fprintf(&devs, `<device id="%s" name="%s"><address>dynamic</address></device>`, devID, name)
	}
	cfg := fmt.Sprintf(`<configuration version="51">
<folder id="magpie" label="Magpie" path="%[1]s" type="receiveencrypted" rescanIntervalS="3600" fsWatcherEnabled="false">
%[2]s
<versioning type="staggered"><param key="maxAge" val="31536000"></param><fsPath>%[6]s</fsPath></versioning>
</folder>
<folder id="magpie-history" label="Magpie history" path="%[6]s" type="sendonly" rescanIntervalS="3600" fsWatcherEnabled="true" fsWatcherDelayS="1">
%[2]s
</folder>
%[3]s
<gui enabled="true" tls="false"><address>127.0.0.1:%[4]d</address><apikey>magpie-test</apikey></gui>
<options>
<listenAddress>tcp://%[5]s</listenAddress>
<globalAnnounceEnabled>false</globalAnnounceEnabled>
<localAnnounceEnabled>false</localAnnounceEnabled>
<relaysEnabled>false</relaysEnabled>
<natEnabled>false</natEnabled>
<urAccepted>-1</urAccepted>
<autoUpgradeIntervalH>0</autoUpgradeIntervalH>
<crashReportingEnabled>false</crashReportingEnabled>
<startBrowser>false</startBrowser>
</options>
</configuration>`, filepath.Join(home, "data"), folderDevs.String(), devs.String(), freePort(t), h.addr, filepath.Join(home, "history"))
	if err := os.WriteFile(filepath.Join(home, "config.xml"), []byte(cfg), 0o600); err != nil {
		t.Fatal(err)
	}
	h.cmd = exec.Command(bin, "serve", "--home", home, "--no-browser", "--no-restart")
	h.cmd.Env = append(os.Environ(), "STNOUPGRADE=1", "TZ=UTC", "STTRACE="+os.Getenv("MAGPIE_HUB_TRACE"))
	logf, _ := os.Create(filepath.Join(home, "hub.log"))
	h.cmd.Stdout, h.cmd.Stderr = logf, logf
	if err := h.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = h.cmd.Process.Kill()
		_, _ = h.cmd.Process.Wait()
		if t.Failed() {
			bs, _ := os.ReadFile(filepath.Join(home, "hub.log"))
			t.Logf("hub log:\n%s", tail(string(bs), 4000))
		}
	})
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		if c, err := net.Dial("tcp", h.addr); err == nil {
			c.Close()
			return h
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("hub did not start listening")
	return nil
}

func tail(s string, n int) string {
	if len(s) > n {
		return s[len(s)-n:]
	}
	return s
}

type device struct {
	*Engine
	cancel context.CancelFunc
}

// newDevice makes a device's state directory and returns "id|dir|name".
func newDevice(t *testing.T, name string) string {
	dir := t.TempDir()
	cert, err := LoadOrCreateCert(dir)
	if err != nil {
		t.Fatal(err)
	}
	return protocol.NewDeviceID(cert.Certificate[0]).String() + "|" + dir + "|" + name
}

func startDevice(t *testing.T, h *hub, spec string) *device {
	parts := strings.SplitN(spec, "|", 3)
	e, err := New(Config{DataDir: parts[1], HubID: h.id, HubAddr: h.addr, FolderID: "magpie", Password: testPassword, DeviceName: parts[2]})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	go e.Run(ctx)
	t.Cleanup(cancel)
	d := &device{Engine: e, cancel: cancel}
	waitFor(t, parts[2]+" ready", func() bool { s := e.Status(); return s.Connected && s.Accepted && s.Ready })
	return d
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

func writeTemp(t *testing.T, content []byte) string {
	f := filepath.Join(t.TempDir(), "src")
	if err := os.WriteFile(f, content, 0o600); err != nil {
		t.Fatal(err)
	}
	return f
}

func fetch(t *testing.T, d *device, name string) []byte {
	t.Helper()
	dst := filepath.Join(t.TempDir(), "dst")
	if _, err := d.Fetch(context.Background(), name, dst, nil); err != nil {
		t.Fatalf("fetch %s: %v", name, err)
	}
	bs, _ := os.ReadFile(dst)
	return bs
}

func twoDevices(t *testing.T) (*hub, *device, *device) {
	mac := newDevice(t, "MacBook Air")
	phone := newDevice(t, "iPhone")
	h := startHub(t, map[string]string{
		strings.SplitN(mac, "|", 2)[0]:   "MacBook Air",
		strings.SplitN(phone, "|", 2)[0]: "iPhone",
	})
	return h, startDevice(t, h, mac), startDevice(t, h, phone)
}

// A file saved on the Mac shows up on the phone, intact, and the server
// holds neither its name nor its content in the clear.
func TestHubSaveOnMacShowsOnPhone(t *testing.T) {
	h, mac, phone := twoDevices(t)
	ctx := context.Background()

	content := bytes.Repeat([]byte("Lisbon, 6 to 10 Nov. Pastéis at Manteigaria.\n"), 50000) // ~2.3 MB, several blocks
	if _, err := mac.Put(ctx, "Trips/Lisbon itinerary.txt", writeTemp(t, content), ""); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the hub to have the file", func() bool {
		en, err := mac.Stat("Trips/Lisbon itinerary.txt")
		return err == nil && en.OnHub
	})
	waitFor(t, "the phone to list the file", func() bool {
		for _, en := range phone.List("Trips") {
			if en.Path == "Trips/Lisbon itinerary.txt" {
				return true
			}
		}
		return false
	})
	if got := fetch(t, phone, "Trips/Lisbon itinerary.txt"); !bytes.Equal(got, content) {
		t.Fatalf("phone got %d bytes, want %d", len(got), len(content))
	}
	if en, _ := phone.Stat("Trips/Lisbon itinerary.txt"); en.ModifiedBy != "MacBook Air" {
		t.Errorf("modified by %q, want MacBook Air", en.ModifiedBy)
	}
	if mac.Status().UploadsLeft != 0 {
		t.Errorf("mac still has %d uploads waiting", mac.Status().UploadsLeft)
	}

	// The server can't read it.
	_ = filepath.WalkDir(filepath.Join(h.home, "data"), func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if strings.Contains(p, "Lisbon") || strings.Contains(p, "Trips") {
			t.Errorf("a plain name is on the server: %s", p)
		}
		if !d.IsDir() {
			bs, _ := os.ReadFile(p)
			if bytes.Contains(bs, []byte("Manteigaria")) {
				t.Errorf("plain content is on the server: %s", p)
			}
		}
		return nil
	})
}

// Both devices edit the same file while the phone is offline. Nothing is
// lost: one edit stays as the file, the other becomes a conflict copy, and
// both devices list the conflict.
func TestHubConflictKeepsBoth(t *testing.T) {
	_, mac, phone := twoDevices(t)
	ctx := context.Background()

	if _, err := mac.Put(ctx, "Budget.numbers", writeTemp(t, []byte("v1")), ""); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "phone sees v1", func() bool { _, err := phone.Stat("Budget.numbers"); return err == nil })
	base, _ := phone.Stat("Budget.numbers")

	phone.Pause()
	waitFor(t, "phone offline", func() bool { return !phone.Status().Connected })
	if _, err := mac.Put(ctx, "Budget.numbers", writeTemp(t, []byte("mac edit")), base.Version); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "mac edit on hub", func() bool { en, _ := mac.Stat("Budget.numbers"); return en.OnHub })
	if _, err := phone.Put(ctx, "Budget.numbers", writeTemp(t, []byte("phone edit")), base.Version); err != nil {
		t.Fatal(err)
	}
	phone.Resume()

	waitFor(t, "both see one conflict", func() bool {
		return len(mac.Conflicts()) == 1 && len(phone.Conflicts()) == 1
	})
	c := mac.Conflicts()[0]
	if c.Original != "Budget.numbers" {
		t.Fatalf("conflict original %q", c.Original)
	}
	if c.CopyEntry.Path != c.Copy || c.OriginalEntry.Path != c.Original || c.CopyEntry.Size == 0 || c.OriginalEntry.Modified.IsZero() {
		t.Fatalf("conflict versions missing: %+v", c)
	}
	got := map[string]bool{string(fetch(t, mac, "Budget.numbers")): true, string(fetch(t, mac, c.Copy)): true}
	if !got["mac edit"] || !got["phone edit"] {
		t.Fatalf("lost an edit: %v", got)
	}

	// Keep both: the copy gets a readable name.
	if err := mac.Resolve(ctx, c, KeepBoth); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "conflict resolved on the phone", func() bool { return len(phone.Conflicts()) == 0 })
	if _, err := phone.Stat("Budget (" + c.CopyBy + ").numbers"); err != nil {
		t.Fatalf("kept copy not found as %q: %v", "Budget ("+c.CopyBy+").numbers", err)
	}
}

// Deleting on one device removes it everywhere and the server keeps the old
// version in its history.
func TestHubDeleteKeepsHistory(t *testing.T) {
	h, mac, phone := twoDevices(t)
	ctx := context.Background()

	if _, err := mac.Put(ctx, "Taxes 2026/Receipt.pdf", writeTemp(t, []byte("%PDF receipt")), ""); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "phone sees it", func() bool { _, err := phone.Stat("Taxes 2026/Receipt.pdf"); return err == nil })
	if err := phone.Delete(ctx, "Taxes 2026", ""); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "mac sees it gone", func() bool { _, err := mac.Stat("Taxes 2026/Receipt.pdf"); return err == ErrNotFound })
	waitFor(t, "the hub keeps a version", func() bool {
		n := 0
		_ = filepath.WalkDir(filepath.Join(h.home, "history"), func(p string, d fs.DirEntry, err error) error {
			if err == nil && !d.IsDir() {
				n++
			}
			return nil
		})
		return n > 0
	})
}

// Empty files and many small edits go through like any other.
func TestHubEmptyAndRepeatedEdits(t *testing.T) {
	_, mac, phone := twoDevices(t)
	ctx := context.Background()
	if _, err := mac.Put(ctx, "empty.txt", writeTemp(t, nil), ""); err != nil {
		t.Fatal(err)
	}
	var base string
	for i := 0; i < 10; i++ {
		en, err := mac.Put(ctx, "log.txt", writeTemp(t, []byte(fmt.Sprintf("line %d", i))), base)
		if err != nil {
			t.Fatal(err)
		}
		base = en.Version
	}
	waitFor(t, "the phone to see the last edit", func() bool {
		en, err := phone.Stat("log.txt")
		return err == nil && en.Version == base
	})
	if got := string(fetch(t, phone, "log.txt")); got != "line 9" {
		t.Fatalf("phone has %q", got)
	}
	if got := fetch(t, phone, "empty.txt"); len(got) != 0 {
		t.Fatalf("empty file has %d bytes", len(got))
	}
	if len(mac.Conflicts()) != 0 {
		t.Fatalf("sequential edits made conflicts: %v", mac.Conflicts())
	}
}

// Old versions come back from the hub's history, decrypted only on the
// devices: listed newest first, fetched intact, restored as a new edit; a
// deleted file can be brought back. The hub's history stays ciphertext.
func TestHubVersionHistory(t *testing.T) {
	h, mac, phone := twoDevices(t)
	ctx := context.Background()

	drafts := [][]byte{
		[]byte("Budget, first draft\n"),
		bytes.Repeat([]byte("Budget, second draft with a lot more rows.\n"), 12000), // ~0.5 MB, several blocks
		[]byte("Budget, final\n"),
	}
	base := ""
	for i, d := range drafts {
		en, err := mac.Put(ctx, "Money/Budget.txt", writeTemp(t, d), base)
		if err != nil {
			t.Fatal(err)
		}
		base = en.Version
		waitFor(t, fmt.Sprintf("draft %d on the hub", i+1), func() bool {
			en, err := mac.Stat("Money/Budget.txt")
			return err == nil && en.OnHub && en.Version == base
		})
		time.Sleep(1100 * time.Millisecond) // the versioner tags by the second
	}

	var versions []OldVersion
	waitFor(t, "the phone to see two old versions", func() bool {
		v, err := phone.Versions(ctx, "Money/Budget.txt")
		versions = v
		return err == nil && len(v) == 2
	})
	for i, want := range [][]byte{drafts[1], drafts[0]} {
		v := versions[i]
		if v.Path != "Money/Budget.txt" || v.Size != int64(len(want)) || v.ModifiedBy != "MacBook Air" {
			t.Fatalf("version %d: %+v", i, v)
		}
		dst := filepath.Join(t.TempDir(), "v")
		if _, err := phone.FetchVersion(ctx, v.ID, dst); err != nil {
			t.Fatalf("fetch version %d: %v", i, err)
		}
		if got, _ := os.ReadFile(dst); !bytes.Equal(got, want) {
			t.Fatalf("version %d came back as %d bytes, want %d", i, len(got), len(want))
		}
	}

	// Restore the first draft from the phone; the Mac gets it as the file.
	if _, err := phone.Restore(ctx, versions[1].ID); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the Mac to have the first draft back", func() bool {
		en, err := mac.Stat("Money/Budget.txt")
		return err == nil && en.Size == int64(len(drafts[0])) && bytes.Equal(fetch(t, mac, "Money/Budget.txt"), drafts[0])
	})

	// A deleted file is listed and comes back.
	if _, err := mac.Put(ctx, "Notes/Packing list.txt", writeTemp(t, []byte("passport, charger")), ""); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the phone sees the list", func() bool { _, err := phone.Stat("Notes/Packing list.txt"); return err == nil })
	if err := phone.Delete(ctx, "Notes/Packing list.txt", ""); err != nil {
		t.Fatal(err)
	}
	var gone []OldVersion
	waitFor(t, "the Mac to list it as deleted", func() bool {
		d, err := mac.Deleted(ctx)
		gone = d
		return err == nil && len(d) > 0 && d[0].Path == "Notes/Packing list.txt"
	})
	if _, err := mac.Restore(ctx, gone[0].ID); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the phone to have it back", func() bool {
		_, err := phone.Stat("Notes/Packing list.txt")
		return err == nil && bytes.Equal(fetch(t, phone, "Notes/Packing list.txt"), []byte("passport, charger"))
	})

	// Nothing in the hub's history is readable there.
	_ = filepath.WalkDir(filepath.Join(h.home, "history"), func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		bs, _ := os.ReadFile(p)
		for _, secret := range []string{"Budget", "passport", "Packing"} {
			if bytes.Contains(bs, []byte(secret)) || strings.Contains(p, secret) {
				t.Fatalf("the hub's history holds %q in the clear (%s)", secret, p)
			}
		}
		return nil
	})
}
