// Copyright (C) 2026 The Magpie Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

// magpie-hubd runs beside the Magpie hub (syncthing holding the folder
// receive-encrypted) and looks after who may connect.
//
//	magpie-hubd init --home DIR --addr HOST:PORT     write the hub's config (once)
//	magpie-hubd run --home DIR                       admit devices with valid invites
//	magpie-hubd setup-link --home DIR                a link for the first device
//	magpie-hubd devices --home DIR                   list devices
//	magpie-hubd remove --home DIR DEVICE-ID          lock a device out
//	magpie-hubd status --home DIR                    JSON for the Magpie page
//
// A device the hub doesn't know is refused by syncthing and shows up as
// pending, with the name it sent in its hello. A joining device puts its
// invite token in that name; if the token is genuine, unused and not
// expired, this adds the device and shares the folder with it, and the
// device's next attempt gets in. Nothing here ever sees file names or
// contents: the hub only holds them encrypted.
package main

import (
	"bytes"
	"encoding/json"
	"encoding/xml"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/syncthing/syncthing/lib/magpie"
	"github.com/syncthing/syncthing/lib/protocol"
)

const folderID = "magpie"

func main() {
	log.SetFlags(0)
	if len(os.Args) < 2 {
		usage()
	}
	cmd := os.Args[1]
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	home := fs.String("home", "/var/lib/magpie", "the hub's syncthing home")
	addr := fs.String("addr", "", "the address devices dial, host:port (init, setup-link)")
	bin := fs.String("syncthing", "syncthing", "the syncthing binary (init)")
	_ = fs.Parse(os.Args[2:])
	h := &hub{home: *home}

	var err error
	switch cmd {
	case "init":
		err = h.init(*bin, *addr)
	case "run":
		err = h.run()
	case "setup-link":
		var link string
		if link, err = h.setupLink(*addr); err == nil {
			fmt.Println(link)
		}
	case "devices":
		err = h.printDevices()
	case "remove":
		if fs.NArg() != 1 {
			usage()
		}
		err = h.remove(fs.Arg(0))
	case "status":
		err = h.printStatus()
	default:
		usage()
	}
	if err != nil {
		log.Fatal("magpie-hubd: ", err)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: magpie-hubd init|run|setup-link|devices|remove|status --home DIR")
	os.Exit(2)
}

type hub struct {
	home   string
	apiKey string
	gui    string
}

func (h *hub) dir() string { return filepath.Join(h.home, "hubd") }

// historyDir holds the folder's old versions, still encrypted. It is shared
// with devices as a send-only folder so they can browse and restore them
// (lib/magpie/history.go); the hub can't read them any more than the rest.
func (h *hub) historyDir() string { return filepath.Join(h.home, "history") }

// init writes the hub's syncthing config: the folder receive-encrypted with
// a year of staggered versions, devices only by invite, and nothing that
// talks to the outside (no discovery, relays, NAT, usage reports, upgrades).
func (h *hub) init(bin, addr string) error {
	if addr == "" {
		return errors.New("init needs --addr host:port")
	}
	if _, err := os.Stat(filepath.Join(h.home, "config.xml")); err == nil {
		return errors.New("already set up (config.xml exists)")
	}
	if out, err := exec.Command(bin, "generate", "--home", h.home).CombinedOutput(); err != nil {
		return fmt.Errorf("syncthing generate: %v: %s", err, out)
	}
	out, err := exec.Command(bin, "device-id", "--home", h.home).Output()
	if err != nil {
		return err
	}
	id := strings.TrimSpace(string(out))
	if err := os.MkdirAll(h.dir(), 0o700); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(h.dir(), "invite.key"), magpie.NewInviteKey(), 0o600); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(h.dir(), "addr"), []byte(addr+"\n"), 0o600); err != nil {
		return err
	}
	_, port, _ := strings.Cut(addr, ":")
	cfg := fmt.Sprintf(`<configuration version="51">
    <folder id="%[1]s" label="Magpie" path="%[2]s" type="receiveencrypted" rescanIntervalS="86400" fsWatcherEnabled="false" ignorePerms="true">
        <device id="%[3]s"></device>
        <versioning type="staggered">
            <param key="maxAge" val="31536000"></param>
            <cleanupIntervalS>3600</cleanupIntervalS>
            <fsPath>%[6]s</fsPath>
        </versioning>
        <minDiskFree unit="%%">2</minDiskFree>
    </folder>
    <folder id="%[7]s" label="Magpie history" path="%[6]s" type="sendonly" rescanIntervalS="3600" fsWatcherEnabled="true" fsWatcherDelayS="1" ignorePerms="true">
        <device id="%[3]s"></device>
    </folder>
    <device id="%[3]s" name="Frankfurt" compression="metadata">
        <address>dynamic</address>
    </device>
    <gui enabled="true" tls="false">
        <address>127.0.0.1:8385</address>
        <apikey>%[4]s</apikey>
    </gui>
    <options>
        <listenAddress>tcp://0.0.0.0:%[5]s</listenAddress>
        <listenAddress>quic://0.0.0.0:%[5]s</listenAddress>
        <globalAnnounceEnabled>false</globalAnnounceEnabled>
        <localAnnounceEnabled>false</localAnnounceEnabled>
        <relaysEnabled>false</relaysEnabled>
        <natEnabled>false</natEnabled>
        <urAccepted>-1</urAccepted>
        <urSeen>3</urSeen>
        <autoUpgradeIntervalH>0</autoUpgradeIntervalH>
        <crashReportingEnabled>false</crashReportingEnabled>
        <startBrowser>false</startBrowser>
        <announceLANAddresses>false</announceLANAddresses>
    </options>
</configuration>
`, folderID, filepath.Join(h.home, "folder"), id, magpie.NewPassword(), port, h.historyDir(), magpie.HistoryFolder(folderID))
	return os.WriteFile(filepath.Join(h.home, "config.xml"), []byte(cfg), 0o600)
}

// loadAPI reads the GUI address and API key from the hub's config.
func (h *hub) loadAPI() error {
	if h.apiKey != "" {
		return nil
	}
	bs, err := os.ReadFile(filepath.Join(h.home, "config.xml"))
	if err != nil {
		return err
	}
	var c struct {
		GUI struct {
			Address string `xml:"address"`
			APIKey  string `xml:"apikey"`
		} `xml:"gui"`
	}
	if err := xml.Unmarshal(bs, &c); err != nil {
		return err
	}
	h.gui, h.apiKey = "http://"+c.GUI.Address, c.GUI.APIKey
	return nil
}

func (h *hub) api(method, path string, body, out any) error {
	if err := h.loadAPI(); err != nil {
		return err
	}
	var rd io.Reader
	if body != nil {
		bs, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(bs)
	}
	req, err := http.NewRequest(method, h.gui+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("X-API-Key", h.apiKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	bs, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("%s %s: %s: %s", method, path, resp.Status, strings.TrimSpace(string(bs)))
	}
	if out != nil && len(bs) > 0 {
		return json.Unmarshal(bs, out)
	}
	return nil
}

func (h *hub) inviteKey() ([]byte, error) { return os.ReadFile(filepath.Join(h.dir(), "invite.key")) }

func (h *hub) setupLink(addr string) (string, error) {
	key, err := h.inviteKey()
	if err != nil {
		return "", err
	}
	if addr == "" {
		bs, err := os.ReadFile(filepath.Join(h.dir(), "addr"))
		if err != nil {
			return "", err
		}
		addr = strings.TrimSpace(string(bs))
	}
	out, err := exec.Command("syncthing", "device-id", "--home", h.home).Output()
	id := strings.TrimSpace(string(out))
	if err != nil || id == "" {
		var st struct {
			MyID string `json:"myID"`
		}
		if err := h.api("GET", "/rest/system/status", nil, &st); err != nil {
			return "", err
		}
		id = st.MyID
	}
	return magpie.Invite{HubID: id, HubAddr: addr, FolderID: folderID, Key: key, Token: magpie.NewToken(key, time.Now())}.Link(), nil
}

type pendingDevice struct {
	Time    time.Time `json:"time"`
	Name    string    `json:"name"`
	Address string    `json:"address"`
}

// run admits devices with valid invites, every two seconds.
func (h *hub) run() error {
	log.Printf("magpie-hubd: watching %s for invited devices", h.home)
	for {
		if err := h.admit(); err != nil {
			log.Printf("magpie-hubd: %v", err)
		}
		if err := h.ensureHistory(); err != nil {
			log.Printf("magpie-hubd: history: %v", err)
		}
		time.Sleep(2 * time.Second)
	}
}

func (h *hub) admit() error {
	key, err := h.inviteKey()
	if err != nil {
		return err
	}
	var pending map[string]pendingDevice
	if err := h.api("GET", "/rest/cluster/pending/devices", nil, &pending); err != nil {
		return err
	}
	for id, p := range pending {
		name, token := magpie.SplitHelloName(p.Name)
		if token == "" {
			continue // a stranger; syncthing already refused it
		}
		devID, err := protocol.DeviceIDFromString(id)
		if err != nil {
			continue
		}
		nonce, err := magpie.CheckToken(key, token, time.Now())
		if err == nil {
			err = h.useNonce(nonce)
		}
		if err != nil {
			log.Printf("magpie-hubd: refused %s (%q) from %s: %v", devID.Short(), name, p.Address, err)
			_ = h.api("DELETE", "/rest/cluster/pending/devices?device="+id, nil, nil)
			continue
		}
		if err := h.add(devID.String(), name); err != nil {
			return err
		}
		log.Printf("magpie-hubd: admitted %s (%q) from %s", devID.Short(), name, p.Address)
	}
	return nil
}

// useNonce records a token's nonce, refusing one already used.
func (h *hub) useNonce(nonce string) error {
	file := filepath.Join(h.dir(), "used.json")
	used := map[string]time.Time{}
	if bs, err := os.ReadFile(file); err == nil {
		_ = json.Unmarshal(bs, &used)
	}
	if _, ok := used[nonce]; ok {
		return errors.New("invite already used")
	}
	for n, t := range used { // tokens last 15 minutes; a day is plenty
		if time.Since(t) > 24*time.Hour {
			delete(used, n)
		}
	}
	used[nonce] = time.Now()
	bs, _ := json.Marshal(used)
	tmp := file + ".tmp"
	if err := os.WriteFile(tmp, bs, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, file)
}

func (h *hub) add(id, name string) error {
	if name == "" {
		name = "Device"
	}
	dev := map[string]any{"deviceID": id, "name": name, "addresses": []string{"dynamic"}, "compression": "metadata"}
	if err := h.api("PUT", "/rest/config/devices/"+id, dev, nil); err != nil {
		return err
	}
	var folder map[string]any
	if err := h.api("GET", "/rest/config/folders/"+folderID, nil, &folder); err != nil {
		return err
	}
	devs, _ := folder["devices"].([]any)
	for _, d := range devs {
		if m, ok := d.(map[string]any); ok && m["deviceID"] == id {
			return nil
		}
	}
	folder["devices"] = append(devs, map[string]any{"deviceID": id})
	return h.api("PUT", "/rest/config/folders/"+folderID, folder, nil)
}

// ensureHistory keeps the history folder in step with the main one: versions
// go to historyDir, and every device of the folder can read its history.
// Hubs set up before history existed get it here.
func (h *hub) ensureHistory() error {
	var folder map[string]any
	if err := h.api("GET", "/rest/config/folders/"+folderID, nil, &folder); err != nil {
		return err
	}
	if v, ok := folder["versioning"].(map[string]any); ok && v["fsPath"] != h.historyDir() {
		v["fsPath"] = h.historyDir()
		if err := h.api("PUT", "/rest/config/folders/"+folderID, folder, nil); err != nil {
			return err
		}
		log.Printf("magpie-hubd: versions now kept in %s", h.historyDir())
	}
	want := map[string]bool{}
	devs, _ := folder["devices"].([]any)
	for _, d := range devs {
		if m, ok := d.(map[string]any); ok {
			if id, _ := m["deviceID"].(string); id != "" {
				want[id] = true
			}
		}
	}

	histID := magpie.HistoryFolder(folderID)
	var hist map[string]any
	if err := h.api("GET", "/rest/config/folders/"+histID, nil, &hist); err != nil {
		if !strings.Contains(err.Error(), "404") {
			return err
		}
		hist = map[string]any{
			"id": histID, "label": "Magpie history", "path": h.historyDir(), "type": "sendonly",
			"rescanIntervalS": 3600, "fsWatcherEnabled": true, "fsWatcherDelayS": 1, "ignorePerms": true,
		}
		log.Printf("magpie-hubd: sharing history from %s", h.historyDir())
	}
	have := map[string]bool{}
	var list []any
	if hd, ok := hist["devices"].([]any); ok {
		for _, d := range hd {
			if m, ok := d.(map[string]any); ok {
				if id, _ := m["deviceID"].(string); want[id] {
					have[id] = true
					list = append(list, d)
				}
			}
		}
	}
	// Devices removed from the folder lose its history too.
	changed := hist["devices"] == nil || len(list) != lenAny(hist["devices"])
	for id := range want {
		if !have[id] {
			list = append(list, map[string]any{"deviceID": id})
			changed = true
		}
	}
	if !changed {
		return nil
	}
	hist["devices"] = list
	return h.api("PUT", "/rest/config/folders/"+histID, hist, nil)
}

func lenAny(v any) int {
	l, _ := v.([]any)
	return len(l)
}

func (h *hub) remove(id string) error {
	devID, err := protocol.DeviceIDFromString(id)
	if err != nil {
		return err
	}
	var st struct {
		MyID string `json:"myID"`
	}
	if err := h.api("GET", "/rest/system/status", nil, &st); err != nil {
		return err
	}
	if devID.String() == st.MyID {
		return errors.New("that is the hub itself")
	}
	return h.api("DELETE", "/rest/config/devices/"+devID.String(), nil, nil)
}

// Device is one device as the page shows it.
type Device struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Connected bool      `json:"connected"`
	LastSeen  time.Time `json:"lastSeen"`
	Client    string    `json:"client,omitempty"`
}

// Status is what the Magpie page shows about the hub.
type Status struct {
	HubID      string    `json:"hubID"`
	Version    string    `json:"version"`
	Uptime     int       `json:"uptimeS"`
	Devices    []Device  `json:"devices"`
	Files      int       `json:"files"`
	Bytes      int64     `json:"bytes"`
	History    int64     `json:"historyBytes"`
	HistoryN   int       `json:"historyFiles"`
	Encrypted  bool      `json:"encrypted"`
	Generated  time.Time `json:"generated"`
	FolderErrs int       `json:"folderErrors"`
}

func (h *hub) status() (Status, error) {
	var s Status
	var sys struct {
		MyID   string `json:"myID"`
		Uptime int    `json:"uptime"`
	}
	if err := h.api("GET", "/rest/system/status", nil, &sys); err != nil {
		return s, err
	}
	var ver struct {
		Version string `json:"version"`
	}
	_ = h.api("GET", "/rest/system/version", nil, &ver)
	var devs []struct {
		DeviceID string `json:"deviceID"`
		Name     string `json:"name"`
	}
	if err := h.api("GET", "/rest/config/devices", nil, &devs); err != nil {
		return s, err
	}
	var conns struct {
		Connections map[string]struct {
			Connected     bool   `json:"connected"`
			ClientVersion string `json:"clientVersion"`
		} `json:"connections"`
	}
	_ = h.api("GET", "/rest/system/connections", nil, &conns)
	var stats map[string]struct {
		LastSeen time.Time `json:"lastSeen"`
	}
	_ = h.api("GET", "/rest/stats/device", nil, &stats)
	var db struct {
		LocalFiles int   `json:"localFiles"`
		LocalBytes int64 `json:"localBytes"`
		Errors     int   `json:"errors"`
		PullErrors int   `json:"pullErrors"`
	}
	_ = h.api("GET", "/rest/db/status?folder="+folderID, nil, &db)

	s.HubID, s.Version, s.Uptime, s.Generated, s.Encrypted = sys.MyID, ver.Version, sys.Uptime, time.Now().UTC(), true
	s.Files, s.Bytes, s.FolderErrs = db.LocalFiles, db.LocalBytes, db.Errors+db.PullErrors
	for _, d := range devs {
		if d.DeviceID == sys.MyID {
			continue
		}
		c := conns.Connections[d.DeviceID]
		s.Devices = append(s.Devices, Device{ID: d.DeviceID, Name: d.Name, Connected: c.Connected, LastSeen: stats[d.DeviceID].LastSeen, Client: c.ClientVersion})
	}
	sort.Slice(s.Devices, func(a, b int) bool { return s.Devices[a].Name < s.Devices[b].Name })
	_ = filepath.Walk(h.historyDir(), func(_ string, fi os.FileInfo, err error) error {
		if err == nil && fi.IsDir() && fi.Name() == ".stfolder" {
			return filepath.SkipDir
		}
		if err == nil && fi.Mode().IsRegular() {
			s.History += fi.Size()
			s.HistoryN++
		}
		return nil
	})
	return s, nil
}

func (h *hub) printStatus() error {
	s, err := h.status()
	if err != nil {
		return err
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(s)
}

func (h *hub) printDevices() error {
	s, err := h.status()
	if err != nil {
		return err
	}
	for _, d := range s.Devices {
		state := "last seen " + d.LastSeen.Format(time.DateTime)
		if d.Connected {
			state = "connected"
		}
		fmt.Printf("%s  %-20s %s\n", d.ID, d.Name, state)
	}
	return nil
}
