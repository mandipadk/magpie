// Copyright (C) 2026 The Magpie Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

package magpie

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"
)

// A new device joins with a link made on a device that already belongs:
//
//	magpie1:join?h=<hub device ID>&a=<host:port>&f=<folder>&k=<invite key>&t=<token>&p=<password>
//
// The token is single use and expires; the hub's helper (magpie-hubd)
// checks it when the new device first connects, then shares the folder with
// it. The password never goes to the hub: the new device needs it to read
// anything, and the link carries it from device to device. The very first
// device gets a link from the server without a password and makes one.

// InviteTTL is how long an invite works.
const InviteTTL = 15 * time.Minute

// joinMark separates a device's name from its join token in the hello, the
// only thing the hub hears from a device it doesn't know yet.
const joinMark = " ~mj1."

// Invite is a parsed join link.
type Invite struct {
	HubID, HubAddr, FolderID string
	Key                      []byte // the invite key, to make more invites
	Token                    string
	Password                 string // empty in the server's first-device link
}

// NewToken makes a token: 8 random bytes, the expiry, and a MAC under key.
func NewToken(key []byte, now time.Time) string {
	var b [12]byte
	_, _ = rand.Read(b[:8])
	binary.BigEndian.PutUint32(b[8:], uint32(now.Add(InviteTTL).Unix()))
	mac := hmac.New(sha256.New, key)
	mac.Write(b[:])
	return base64.RawURLEncoding.EncodeToString(append(b[:], mac.Sum(nil)[:16]...))
}

// CheckToken verifies a token's MAC and expiry and returns its nonce (for
// the caller to refuse a second use).
func CheckToken(key []byte, token string, now time.Time) (nonce string, err error) {
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil || len(raw) != 28 {
		return "", errors.New("magpie: malformed invite")
	}
	mac := hmac.New(sha256.New, key)
	mac.Write(raw[:12])
	if !hmac.Equal(mac.Sum(nil)[:16], raw[12:]) {
		return "", errors.New("magpie: invite not made by this Magpie")
	}
	if exp := time.Unix(int64(binary.BigEndian.Uint32(raw[8:12])), 0); now.After(exp) {
		return "", errors.New("magpie: invite expired")
	}
	return base64.RawURLEncoding.EncodeToString(raw[:8]), nil
}

// Link renders the invite as a magpie1: link.
func (in Invite) Link() string {
	q := url.Values{}
	q.Set("h", in.HubID)
	q.Set("a", in.HubAddr)
	q.Set("f", in.FolderID)
	q.Set("k", base64.RawURLEncoding.EncodeToString(in.Key))
	q.Set("t", in.Token)
	if in.Password != "" {
		q.Set("p", in.Password)
	}
	return "magpie1:join?" + q.Encode()
}

// ParseInvite reads a magpie1: link.
func ParseInvite(link string) (Invite, error) {
	link = strings.TrimSpace(link)
	rest, ok := strings.CutPrefix(link, "magpie1:join?")
	if !ok {
		return Invite{}, errors.New("magpie: not a Magpie link")
	}
	q, err := url.ParseQuery(rest)
	if err != nil {
		return Invite{}, fmt.Errorf("magpie: link: %w", err)
	}
	key, err := base64.RawURLEncoding.DecodeString(q.Get("k"))
	if err != nil || len(key) < 16 {
		return Invite{}, errors.New("magpie: link has no invite key")
	}
	in := Invite{HubID: q.Get("h"), HubAddr: q.Get("a"), FolderID: q.Get("f"), Key: key, Token: q.Get("t"), Password: q.Get("p")}
	if in.HubID == "" || in.HubAddr == "" || in.FolderID == "" || in.Token == "" {
		return Invite{}, errors.New("magpie: link is incomplete")
	}
	return in, nil
}

// HelloName is what a joining device sends as its name: the name and its
// token, so the hub's helper can let it in.
func HelloName(name, token string) string {
	if token == "" {
		return name
	}
	return name + joinMark + token
}

// SplitHelloName undoes HelloName.
func SplitHelloName(s string) (name, token string) {
	name, token, _ = strings.Cut(s, joinMark)
	return name, token
}

// NewPassword makes a folder password for the first device.
func NewPassword() string {
	var b [24]byte
	_, _ = rand.Read(b[:])
	return base64.RawURLEncoding.EncodeToString(b[:])
}

// NewInviteKey makes the hub's invite key.
func NewInviteKey() []byte {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return b
}

// ConfigFromInvite is the engine config for a device joining with in. The
// first device, whose link from the server has no password, makes one.
func ConfigFromInvite(in Invite, dataDir, deviceName string) Config {
	pw := in.Password
	if pw == "" {
		pw = NewPassword()
	}
	return Config{
		DataDir:    dataDir,
		HubID:      in.HubID,
		HubAddr:    in.HubAddr,
		FolderID:   in.FolderID,
		Password:   pw,
		DeviceName: deviceName,
		JoinToken:  in.Token,
		InviteKey:  in.Key,
	}
}
