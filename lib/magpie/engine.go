// Copyright (C) 2026 The Magpie Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

// Package magpie is the engine of the Magpie apps: a small, on-demand
// Syncthing peer that talks to one hub (the always-on server) and keeps
// nothing but what it is asked for.
//
// The hub holds the folder as an untrusted, receive-encrypted device. This
// engine is a trusted device: it holds the folder password, so everything it
// sends is encrypted before it leaves and everything it receives is decrypted
// here. The hub only ever sees encrypted names and blocks.
//
// Unlike a full Syncthing device, the engine does not mirror the folder. It
// keeps the hub's (decrypted) index, fetches a file's blocks when an app asks
// for it, and announces only the files this device changed. Conflicts are
// never resolved silently: the losing edit is kept as a conflict copy next to
// the original and reported.
package magpie

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/tlsutil"
)

// Config says where the hub is and which folder to use.
type Config struct {
	// DataDir holds the device certificate, the index and pending uploads.
	DataDir string
	// HubID is the hub's device ID.
	HubID string
	// HubAddr is host:port of the hub (TCP).
	HubAddr string
	// FolderID is the Syncthing folder ID shared with the hub.
	FolderID string
	// Password is the folder's encryption password. It never leaves this
	// device; the hub gets only a token derived from it.
	Password string
	// DeviceName is how this device introduces itself ("MacBook Air").
	DeviceName string
	// JoinToken is the invite token this device joins with; it is sent
	// until the hub accepts the device.
	JoinToken string
	// InviteKey lets this device make invites for others.
	InviteKey []byte
}

// Engine is one device's view of the folder.
type Engine struct {
	cfg    Config
	cert   tls.Certificate
	myID   protocol.DeviceID
	hubID  protocol.DeviceID
	keyGen *protocol.KeyGenerator

	store *store
	out   *outbox

	mu           sync.Mutex
	conn         protocol.Connection
	connected    chan struct{} // closed while connected; replaced on disconnect
	paused       bool
	lastErr      error
	hubMax       int64 // the hub's index sequence as of its cluster config
	shared       bool  // the hub shares the folder with us
	names        map[string]string
	devices      []DeviceInfo
	fkey         *[32]byte             // the folder key, derived once (history.go)
	versionCache map[string]OldVersion // trailers already read
	changes      *changeLog

	listeners []func(Change)
	stopped   chan struct{}
}

// ChangeKind says what happened.
type ChangeKind int

const (
	// Changed: the paths changed on the hub (new, edited or deleted).
	Changed ChangeKind = iota
	// Uploaded: this device's edit is now on the hub.
	Uploaded
	// Conflicted: an edit lost to another device's; it was kept as a copy.
	Conflicted
	// StatusChanged: connection or progress changed.
	StatusChanged
)

// Change is passed to listeners.
type Change struct {
	Kind  ChangeKind
	Paths []string
}

// New opens (or creates) the engine state in cfg.DataDir.
func New(cfg Config) (*Engine, error) {
	if cfg.DataDir == "" || cfg.FolderID == "" || cfg.Password == "" {
		return nil, errors.New("magpie: DataDir, FolderID and Password are required")
	}
	hubID, err := protocol.DeviceIDFromString(cfg.HubID)
	if err != nil {
		return nil, fmt.Errorf("magpie: hub ID: %w", err)
	}
	if err := os.MkdirAll(cfg.DataDir, 0o700); err != nil {
		return nil, err
	}
	if err := lockDataDir(cfg.DataDir); err != nil {
		return nil, err
	}
	cert, err := LoadOrCreateCert(cfg.DataDir)
	if err != nil {
		return nil, err
	}
	st, err := openStore(filepath.Join(cfg.DataDir, "index.gob"))
	if err != nil {
		return nil, err
	}
	ob, err := openOutbox(filepath.Join(cfg.DataDir, "outbox"))
	if err != nil {
		return nil, err
	}
	e := &Engine{
		cfg:       cfg,
		cert:      cert,
		myID:      protocol.NewDeviceID(cert.Certificate[0]),
		hubID:     hubID,
		keyGen:    protocol.NewKeyGenerator(),
		store:     st,
		out:       ob,
		connected: make(chan struct{}),
		stopped:   make(chan struct{}),
		changes:   newChangeLog(),
	}
	return e, nil
}

// LoadOrCreateCert returns this device's certificate, making one the first
// time. The device ID is the hash of it.
func LoadOrCreateCert(dir string) (tls.Certificate, error) {
	certFile, keyFile := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	if cert, err := tls.LoadX509KeyPair(certFile, keyFile); err == nil {
		return cert, nil
	}
	return tlsutil.NewCertificate(certFile, keyFile, "syncthing", 20*365, false)
}

// DeviceID is this device's Syncthing device ID.
func (e *Engine) DeviceID() string { return e.myID.String() }

// OnChange registers a listener. Listeners run on the engine's goroutines and
// must not block.
func (e *Engine) OnChange(f func(Change)) {
	e.mu.Lock()
	e.listeners = append(e.listeners, f)
	e.mu.Unlock()
}

func (e *Engine) emit(c Change) {
	if c.Kind == Changed && len(c.Paths) > 0 {
		e.changes.add(c.Paths)
	}
	e.mu.Lock()
	ls := append([]func(Change){}, e.listeners...)
	e.mu.Unlock()
	for _, f := range ls {
		f(c)
	}
}

// Run keeps a connection to the hub until ctx ends, reconnecting with
// backoff.
func (e *Engine) Run(ctx context.Context) {
	defer close(e.stopped)
	backoff := time.Second
	for ctx.Err() == nil {
		if e.isPaused() {
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Second):
			}
			continue
		}
		start := time.Now()
		err := e.connectOnce(ctx)
		e.setErr(err)
		if err != nil {
			slog.Debug("magpie: hub connection ended", "err", err)
		}
		if time.Since(start) > time.Minute {
			backoff = time.Second
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, time.Minute)
	}
}

// Pause disconnects and stays disconnected until Resume.
func (e *Engine) Pause() {
	e.mu.Lock()
	e.paused = true
	c := e.conn
	e.mu.Unlock()
	if c != nil {
		c.Close(errors.New("paused"))
	}
	e.emit(Change{Kind: StatusChanged})
}

// Resume undoes Pause.
func (e *Engine) Resume() {
	e.mu.Lock()
	e.paused = false
	e.mu.Unlock()
	e.emit(Change{Kind: StatusChanged})
}

func (e *Engine) isPaused() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.paused
}

func (e *Engine) setErr(err error) {
	e.mu.Lock()
	e.lastErr = err
	e.mu.Unlock()
}

// connectOnce dials the hub, runs the connection and returns when it closes.
func (e *Engine) connectOnce(ctx context.Context) error {
	tlsCfg := tlsutil.SecureDefaultTLS13()
	tlsCfg.Certificates = []tls.Certificate{e.cert}
	tlsCfg.NextProtos = []string{"bep/1.0"}
	tlsCfg.InsecureSkipVerify = true // the peer is checked by device ID below
	tlsCfg.SessionTicketsDisabled = true

	d := &net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}
	raw, err := d.DialContext(ctx, "tcp", e.cfg.HubAddr)
	if err != nil {
		return err
	}
	tc := tls.Client(raw, tlsCfg)
	hctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if err := tc.HandshakeContext(hctx); err != nil {
		raw.Close()
		return err
	}
	certs := tc.ConnectionState().PeerCertificates
	if len(certs) != 1 || protocol.NewDeviceID(certs[0].Raw) != e.hubID {
		tc.Close()
		return errors.New("magpie: the server's certificate is not the expected hub")
	}

	_ = tc.SetDeadline(time.Now().Add(20 * time.Second))
	_, err = protocol.ExchangeHello(tc, protocol.Hello{
		DeviceName:    e.helloName(),
		ClientName:    "magpie",
		ClientVersion: Version,
		Timestamp:     time.Now().UnixNano(),
	})
	if err != nil {
		tc.Close()
		return fmt.Errorf("magpie: hello: %w", err)
	}
	_ = tc.SetDeadline(time.Time{})

	info := &connInfo{raw: tc, established: time.Now()}
	m := &model{e: e}
	conn := protocol.NewConnection(e.hubID, tc, tc, tc, m, info, protocol.CompressionMetadata, e.keyGen)
	m.conn = conn
	conn.Start()
	conn.ClusterConfig(e.clusterConfig(), map[string]string{e.cfg.FolderID: e.cfg.Password})

	e.mu.Lock()
	e.conn = conn
	close(e.connected)
	e.mu.Unlock()
	e.emit(Change{Kind: StatusChanged})

	// Our own index, in full, every time: the hub then knows exactly which
	// versions it may pull from us.
	if err := e.sendIndex(ctx, conn); err != nil {
		conn.Close(err)
	}

	select {
	case <-ctx.Done():
		conn.Close(ctx.Err())
		<-conn.Closed()
	case <-conn.Closed():
	}

	e.mu.Lock()
	e.conn = nil
	e.connected = make(chan struct{})
	e.mu.Unlock()
	e.emit(Change{Kind: StatusChanged})
	return errors.New("magpie: disconnected")
}

func (e *Engine) helloName() string {
	if e.store.isJoined() {
		return e.cfg.DeviceName
	}
	return HelloName(e.cfg.DeviceName, e.cfg.JoinToken)
}

// Invite makes a single-use link for another device to join, with the
// newest invite key the hub has published (see keys.go).
func (e *Engine) Invite() (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), inviteKeyTimeout)
	defer cancel()
	key := e.inviteKey(ctx)
	if len(key) == 0 {
		return "", errors.New("magpie: this device can't make invites")
	}
	return Invite{
		HubID:    e.hubID.String(),
		HubAddr:  e.cfg.HubAddr,
		FolderID: e.cfg.FolderID,
		Key:      key,
		Token:    NewToken(key, time.Now()),
		Password: e.cfg.Password,
	}.Link(), nil
}

func (e *Engine) clusterConfig() *protocol.ClusterConfig {
	hubIdx, hubSeq := e.store.hubIndexState()
	myIdx, mySeq := e.store.localIndexState()
	histIdx, histSeq := e.store.histIndexState()
	return &protocol.ClusterConfig{
		Folders: []protocol.Folder{{
			ID:    e.cfg.FolderID,
			Label: "Magpie",
			Devices: []protocol.Device{
				{
					ID:                      e.myID,
					Name:                    e.cfg.DeviceName,
					Compression:             protocol.CompressionMetadata,
					IndexID:                 myIdx,
					MaxSequence:             mySeq,
					EncryptionPasswordToken: nil,
				},
				{
					ID:                      e.hubID,
					Compression:             protocol.CompressionMetadata,
					IndexID:                 hubIdx,
					MaxSequence:             hubSeq,
					EncryptionPasswordToken: protocol.PasswordToken(e.keyGen, e.cfg.FolderID, e.cfg.Password),
				},
			},
		}, {
			// The hub's old versions, already ciphertext, shared as plain files
			// (see history.go). We only ever read from it.
			ID:    HistoryFolder(e.cfg.FolderID),
			Label: "Magpie history",
			Devices: []protocol.Device{
				{ID: e.myID, Name: e.cfg.DeviceName, Compression: protocol.CompressionMetadata, IndexID: myIdx},
				{ID: e.hubID, Compression: protocol.CompressionMetadata, IndexID: histIdx, MaxSequence: histSeq},
			},
		}},
	}
}

func (e *Engine) sendIndex(ctx context.Context, conn protocol.Connection) error {
	files, last := e.store.localFiles()
	return conn.Index(ctx, &protocol.Index{Folder: e.cfg.FolderID, Files: files, LastSequence: last})
}

// currentConn returns the live connection, waiting up to the context's
// deadline for one.
func (e *Engine) currentConn(ctx context.Context) (protocol.Connection, error) {
	for {
		e.mu.Lock()
		c, ch, paused := e.conn, e.connected, e.paused
		e.mu.Unlock()
		if paused {
			return nil, ErrPaused
		}
		if c != nil {
			return c, nil
		}
		select {
		case <-ch:
		case <-ctx.Done():
			return nil, ErrOffline
		}
	}
}

var (
	// ErrOffline means the hub could not be reached in time.
	ErrOffline = errors.New("magpie: the server can't be reached")
	// ErrPaused means syncing is paused.
	ErrPaused = errors.New("magpie: syncing is paused")
	// ErrNotFound means there is no such file.
	ErrNotFound = errors.New("magpie: no such file")
)

// Version is the engine's version, sent in the hello.
var Version = "0.1.0"

type connInfo struct {
	raw         *tls.Conn
	established time.Time
}

func (c *connInfo) Type() string             { return "tcp-client" }
func (c *connInfo) Transport() string        { return "tcp" }
func (c *connInfo) IsLocal() bool            { return false }
func (c *connInfo) RemoteAddr() net.Addr     { return c.raw.RemoteAddr() }
func (c *connInfo) Priority() int            { return 10 }
func (c *connInfo) String() string           { return c.raw.RemoteAddr().String() }
func (c *connInfo) Crypto() string           { return "TLS1.3" }
func (c *connInfo) EstablishedAt() time.Time { return c.established }
func (c *connInfo) ConnectionID() string     { return fmt.Sprintf("magpie-%d", c.established.UnixNano()) }
