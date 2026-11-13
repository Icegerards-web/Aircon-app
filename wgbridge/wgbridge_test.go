package wgbridge

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"testing"

	"golang.org/x/crypto/curve25519"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

func keypair(t *testing.T) (priv, pub []byte) {
	priv = make([]byte, 32)
	rand.Read(priv)
	priv[0] &= 248
	priv[31] = (priv[31] & 127) | 64
	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		t.Fatal(err)
	}
	return
}

// A fake "home": a WireGuard server whose inside network has a web server standing in for an aircon adapter.
func TestPostThroughTunnel(t *testing.T) {
	sp, spub := keypair(t)
	cp, cpub := keypair(t)

	// find a free UDP port
	pc, _ := net.ListenPacket("udp4", "127.0.0.1:0")
	port := pc.LocalAddr().(*net.UDPAddr).Port
	pc.Close()

	stun, snet, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.9.0.1")}, nil, 1280)
	if err != nil {
		t.Fatal(err)
	}
	sd := device.NewDevice(stun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelSilent, ""))
	defer sd.Close()
	err = sd.IpcSet(fmt.Sprintf("private_key=%s\nlisten_port=%d\npublic_key=%s\nallowed_ip=10.9.0.2/32\n",
		hex.EncodeToString(sp), port, hex.EncodeToString(cpub)))
	if err != nil {
		t.Fatal(err)
	}
	sd.Up()
	ln, err := snet.ListenTCP(&net.TCPAddr{Port: 51443})
	if err != nil {
		t.Fatal(err)
	}
	go http.Serve(ln, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		fmt.Fprintf(w, `{"result":0,"echo":%q,"path":%q}`, string(b), r.URL.Path)
	}))

	conf := fmt.Sprintf("[Interface]\nPrivateKey = %s\nAddress = 10.9.0.2/32\n\n[Peer]\nPublicKey = %s\nEndpoint = 127.0.0.1:%d\nAllowedIPs = 10.9.0.0/24\nPersistentKeepalive = 25\n",
		base64.StdEncoding.EncodeToString(cp), base64.StdEncoding.EncodeToString(spub), port)
	if msg := Validate(conf); msg != "" {
		t.Fatal(msg)
	}
	if err := Start(conf); err != nil {
		t.Fatal(err)
	}
	defer Stop()
	if !IsRunning() {
		t.Fatal("should be running")
	}
	r, err := Post("http://10.9.0.1:51443/beaver/command/getDeviceInfo", []byte(`{"hello":1}`), 10)
	if err != nil {
		t.Fatal(err)
	}
	if r.Status() != 200 || !strings.Contains(string(r.Body()), `"path":"/beaver/command/getDeviceInfo"`) {
		t.Fatalf("unexpected reply %d %s", r.Status(), r.Body())
	}
	t.Logf("reply: %s", r.Body())
}

func TestValidateProblems(t *testing.T) {
	for _, c := range []string{"", "[Interface]\nAddress=10.0.0.2/32", "[Interface]\nPrivateKey=abc\nAddress=10.0.0.2/32"} {
		if Validate(c) == "" {
			t.Errorf("expected a problem for %q", c)
		}
	}
}
