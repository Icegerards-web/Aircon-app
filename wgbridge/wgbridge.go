// Package wgbridge runs WireGuard *inside the app* (in memory, no system VPN) and lets the app send HTTP requests
// through it. This needs no Network Extension permission, so it works with a free Apple ID, shows no VPN icon,
// and only the app's own requests to the aircons use the tunnel.
//
// It is compiled to an iOS framework with gomobile (see the CI workflows) and used from Swift as `Wgbridge`.
package wgbridge

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

var (
	mu   sync.Mutex
	dev  *device.Device
	tnet *netstack.Net
)

// Reply is an HTTP answer (gomobile can't return plain structs, so it has getters).
type Reply struct {
	status int
	body   []byte
}

func (r *Reply) Status() int  { return r.status }
func (r *Reply) Body() []byte { return r.body }

// Start brings the tunnel up from a standard WireGuard config file ("wg-quick" format).
// Calling it while a tunnel is running replaces that tunnel.
func Start(conf string) error {
	cfg, err := parseConf(conf)
	if err != nil {
		return err
	}
	mu.Lock()
	defer mu.Unlock()
	stopLocked()

	mtu := cfg.mtu
	if mtu == 0 {
		mtu = 1280 // small enough to survive mobile networks
	}
	tun, net2, err := netstack.CreateNetTUN(cfg.addresses, cfg.dns, mtu)
	if err != nil {
		return fmt.Errorf("create tunnel: %w", err)
	}
	d := device.NewDevice(tun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelError, "wg: "))
	if err := d.IpcSet(cfg.ipc); err != nil {
		d.Close()
		return fmt.Errorf("apply config: %w", err)
	}
	if err := d.Up(); err != nil {
		d.Close()
		return fmt.Errorf("start tunnel: %w", err)
	}
	dev, tnet = d, net2
	return nil
}

// Stop closes the tunnel (safe to call when nothing is running).
func Stop() {
	mu.Lock()
	defer mu.Unlock()
	stopLocked()
}

func stopLocked() {
	if dev != nil {
		dev.Close()
	}
	dev, tnet = nil, nil
}

// IsRunning says whether a tunnel is up.
func IsRunning() bool {
	mu.Lock()
	defer mu.Unlock()
	return dev != nil
}

// Validate checks a config without starting anything. Returns "" when it looks right, otherwise a readable problem.
func Validate(conf string) string {
	if _, err := parseConf(conf); err != nil {
		return err.Error()
	}
	return ""
}

// Post sends an HTTP POST with a JSON body through the tunnel (http:// or https://, certificate not checked:
// the adapters use self-made certificates).
func Post(url string, body []byte, timeoutSeconds int) (*Reply, error) {
	mu.Lock()
	n := tnet
	mu.Unlock()
	if n == nil {
		return nil, errors.New("the tunnel is not running")
	}
	if timeoutSeconds <= 0 {
		timeoutSeconds = 25
	}
	var suites []uint16
	for _, s := range tls.CipherSuites() {
		suites = append(suites, s.ID)
	}
	for _, s := range tls.InsecureCipherSuites() { // old adapters only know old suites
		suites = append(suites, s.ID)
	}
	tr := &http.Transport{
		DialContext:       n.DialContext,
		DisableKeepAlives: true,
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: true,
			MinVersion:         tls.VersionTLS10,
			CipherSuites:       suites,
		},
		TLSNextProto: map[string]func(string, *tls.Conn) http.RoundTripper{}, // HTTP/1.1 only
	}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: time.Duration(timeoutSeconds) * time.Second}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutSeconds)*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	return &Reply{status: resp.StatusCode, body: data}, nil
}

// ---- config parsing ------------------------------------------------------------

type config struct {
	addresses []netip.Addr
	dns       []netip.Addr
	mtu       int
	ipc       string
}

func b64ToHex(s string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(s))
	if err != nil || len(raw) != 32 {
		return "", errors.New("a key in the config is not valid (expected 44 characters ending in =)")
	}
	return hex.EncodeToString(raw), nil
}

func parseConf(conf string) (*config, error) {
	cfg := &config{}
	var section string
	var ipc strings.Builder
	var peers [][]string // lines per peer
	var iface []string
	var cur *[]string
	var havePriv, havePeer bool

	for _, line := range strings.Split(conf, "\n") {
		line = strings.TrimSpace(line)
		if i := strings.Index(line, "#"); i >= 0 {
			line = strings.TrimSpace(line[:i])
		}
		if line == "" {
			continue
		}
		low := strings.ToLower(line)
		if low == "[interface]" {
			section = "interface"
			cur = &iface
			continue
		}
		if low == "[peer]" {
			section = "peer"
			peers = append(peers, nil)
			cur = &peers[len(peers)-1]
			continue
		}
		if section == "" || cur == nil {
			continue
		}
		*cur = append(*cur, line)
		_ = section
	}
	// rebuild: peers slice may have been reallocated, so re-parse peers separately
	peers = splitPeers(conf)

	for _, l := range iface {
		k, v, ok := splitKV(l)
		if !ok {
			continue
		}
		switch strings.ToLower(k) {
		case "privatekey":
			h, err := b64ToHex(v)
			if err != nil {
				return nil, err
			}
			fmt.Fprintf(&ipc, "private_key=%s\n", h)
			havePriv = true
		case "address":
			for _, a := range strings.Split(v, ",") {
				p, err := netip.ParsePrefix(strings.TrimSpace(a))
				if err != nil {
					ad, err2 := netip.ParseAddr(strings.TrimSpace(a))
					if err2 != nil {
						return nil, fmt.Errorf("the Address \"%s\" is not valid", strings.TrimSpace(a))
					}
					cfg.addresses = append(cfg.addresses, ad)
					continue
				}
				cfg.addresses = append(cfg.addresses, p.Addr())
			}
		case "dns":
			for _, a := range strings.Split(v, ",") {
				if ad, err := netip.ParseAddr(strings.TrimSpace(a)); err == nil {
					cfg.dns = append(cfg.dns, ad)
				}
			}
		case "mtu":
			if n, err := strconv.Atoi(v); err == nil {
				cfg.mtu = n
			}
		}
	}
	if !havePriv {
		return nil, errors.New("the config has no PrivateKey in its [Interface] section")
	}
	if len(cfg.addresses) == 0 {
		return nil, errors.New("the config has no Address in its [Interface] section")
	}
	for _, pl := range peers {
		var peer strings.Builder
		var havePub, haveEndpoint bool
		for _, l := range pl {
			k, v, ok := splitKV(l)
			if !ok {
				continue
			}
			switch strings.ToLower(k) {
			case "publickey":
				h, err := b64ToHex(v)
				if err != nil {
					return nil, err
				}
				fmt.Fprintf(&peer, "public_key=%s\n", h)
				havePub = true
			case "presharedkey":
				h, err := b64ToHex(v)
				if err != nil {
					return nil, err
				}
				fmt.Fprintf(&peer, "preshared_key=%s\n", h)
			case "endpoint":
				ua, err := net.ResolveUDPAddr("udp", v)
				if err != nil {
					return nil, fmt.Errorf("can't find the server \"%s\" (check the Endpoint and your internet connection)", v)
				}
				fmt.Fprintf(&peer, "endpoint=%s\n", ua.String())
				haveEndpoint = true
			case "allowedips":
				for _, a := range strings.Split(v, ",") {
					a = strings.TrimSpace(a)
					if _, err := netip.ParsePrefix(a); err != nil {
						return nil, fmt.Errorf("the AllowedIPs entry \"%s\" is not valid", a)
					}
					fmt.Fprintf(&peer, "allowed_ip=%s\n", a)
				}
			case "persistentkeepalive":
				if n, err := strconv.Atoi(v); err == nil {
					fmt.Fprintf(&peer, "persistent_keepalive_interval=%d\n", n)
				}
			}
		}
		if !havePub {
			return nil, errors.New("a [Peer] in the config has no PublicKey")
		}
		if !haveEndpoint {
			return nil, errors.New("the [Peer] in the config has no Endpoint (the address of your home WireGuard server)")
		}
		ipc.WriteString(peer.String())
		havePeer = true
	}
	if !havePeer {
		return nil, errors.New("the config has no [Peer] section")
	}
	cfg.ipc = ipc.String()
	return cfg, nil
}

func splitPeers(conf string) [][]string {
	var peers [][]string
	in := false
	for _, line := range strings.Split(conf, "\n") {
		line = strings.TrimSpace(line)
		if i := strings.Index(line, "#"); i >= 0 {
			line = strings.TrimSpace(line[:i])
		}
		if line == "" {
			continue
		}
		low := strings.ToLower(line)
		if low == "[peer]" {
			peers = append(peers, nil)
			in = true
			continue
		}
		if strings.HasPrefix(low, "[") {
			in = false
			continue
		}
		if in {
			peers[len(peers)-1] = append(peers[len(peers)-1], line)
		}
	}
	return peers
}

func splitKV(l string) (string, string, bool) {
	i := strings.Index(l, "=")
	if i < 0 {
		return "", "", false
	}
	return strings.TrimSpace(l[:i]), strings.TrimSpace(l[i+1:]), true
}
