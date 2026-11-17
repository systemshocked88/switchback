package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"crypto/md5"
	"encoding/json"
	"switchback/internal/fakessh"
)

const fakePriv = "aFakePrivateKeyForTestsOnly0123456789abcdE="

func TestStatusWireGuardUninstall(t *testing.T) {
	sh := fakessh.FindSh()
	if sh == "" {
		t.Skip("no POSIX sh")
	}
	repo, _ := filepath.Abs("..")
	work := t.TempDir()
	fake := filepath.Join(work, "opt")
	if err := fakessh.MakeFakeKeenetic(sh, repo, fake); err != nil {
		t.Fatal(err)
	}
	host, port := serve(t, sh, []string{"SB_OPT=" + fakessh.PosixPath(fake), "SB_TEST=1", "SB_PLATFORM=keenetic"}, fakessh.NewKey())
	a := NewApp()
	a.kh = &knownHosts{path: filepath.Join(work, "known_hosts")}
	a.remoteDir = fakessh.PosixPath(filepath.Join(work, "remote"))
	var evs []sbEvent
	var logs []string
	a.emit = func(name string, data any) {
		if name == "sb:event" {
			evs = append(evs, data.(sbEvent))
		} else {
			logs = append(logs, data.(string))
		}
	}
	if r := a.Connect(host, port, "root", "secret"); !r.OK {
		t.Fatal(r.Error)
	}
	defer a.Disconnect()

	// nothing installed yet
	if r := a.Status(); !r.OK {
		t.Fatalf("status: %+v", r)
	}

	// WireGuard from a file: not a WireGuard file is refused before anything is sent
	bad := filepath.Join(work, "bad.conf")
	os.WriteFile(bad, []byte("hello"), 0o600)
	if r := a.importWireGuardFile(bad, false); r.OK || !strings.Contains(r.Error, "WireGuard") {
		t.Fatalf("bad file: %+v", r)
	}
	conf := filepath.Join(work, "vpn.conf")
	os.WriteFile(conf, []byte("[Interface]\r\nPrivateKey = "+fakePriv+"\r\nAddress = 10.8.0.2/32\r\n\r\n[Peer]\r\n"+
		"PublicKey = SERVERpubKEYforTESTSonly0123456789abcdefgh=\r\nEndpoint = 198.51.100.7:51820\r\nAllowedIPs = 0.0.0.0/0\r\n"), 0o600)
	logs = nil
	r := a.importWireGuardFile(conf, false)
	if !r.OK || r.Name != "Wireguard2" {
		t.Fatalf("import: %+v\n%s", r, strings.Join(logs, "\n"))
	}
	for _, l := range logs {
		if strings.Contains(l, fakePriv) {
			t.Fatal("private key shown in the window log")
		}
	}
	if _, err := os.Stat(filepath.Join(work, "remote", "wg.conf")); err == nil {
		t.Fatal("conf copy left on the router")
	}
	if b, _ := os.ReadFile(filepath.Join(work, "remote", "run.log")); strings.Contains(string(b), fakePriv) {
		t.Fatal("private key in run.log")
	}

	// status sees it; "roll back everything" removes it
	evs = nil
	a.Status()
	found := false
	for _, e := range evs {
		if e.Kind == "item" && strings.Contains(e.Fields[1], "Wireguard2") {
			found = true
		}
	}
	if !found {
		t.Fatal("status does not show the new connection")
	}
	if r := a.Uninstall(false); !r.OK {
		t.Fatalf("uninstall: %+v\n%s", r, strings.Join(logs, "\n"))
	}
	ndm, _ := os.ReadFile(filepath.Join(fake, "ndmc.log"))
	if !strings.Contains(string(ndm), "no interface Wireguard2") {
		t.Fatal("rollback did not remove the connection")
	}
}

func TestCheckModelAndImage(t *testing.T) {
	image := []byte("pretend this is an OpenWrt factory image")
	sum := sha256.Sum256(image)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.versions.json":
			w.Write([]byte(`{"stable_version":"25.12.6","oldstable_version":"24.10.8"}`))
		case "/releases/25.12.6/.overview.json":
			w.Write([]byte(`{"release":"25.12.6","profiles":[
			 {"id":"xiaomi_mi-router-ax3000t","titles":[{"model":"Mi Router AX3000T","vendor":"Xiaomi"}],"target":"mediatek/filogic"},
			 {"id":"tplink_archer-c6-v2","titles":[{"model":"Archer C6","variant":"v2 (EU/RU/JP)","vendor":"TP-Link"}],"target":"ath79/generic"},
			 {"id":"tplink_archer-c6-v3","titles":[{"model":"Archer C6","variant":"V3","vendor":"TP-Link"}],"target":"ramips/mt7621"},
			 {"id":"tplink_archer-c60-v3","titles":[{"model":"Archer C60","variant":"v3","vendor":"TP-Link"}],"target":"ramips/mt76x8"},
			 {"id":"generic","titles":[{"title":"Generic EFI Boot"}],"target":"armsr/armv8"}]}`))
		case "/releases/25.12.6/targets/ramips/mt7621/profiles.json":
			fmt.Fprintf(w, `{"profiles":{"tplink_archer-c6-v3":{"images":[
			 {"name":"x-factory.bin","type":"factory","sha256":"%s"},
			 {"name":"x-sysupgrade.bin","type":"sysupgrade","sha256":"00"}]}}}`, hex.EncodeToString(sum[:]))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	old := openwrtBase
	openwrtBase = srv.URL
	defer func() { openwrtBase = old }()
	owCache.version, owCache.profiles = "", nil

	a := NewApp()
	if r := a.CheckModel("x"); r.Error == "" {
		t.Fatal("too short query accepted")
	}
	r := a.CheckModel("archer c6 v3")
	if r.Error != "" || len(r.Matches) != 1 || r.Matches[0].ID != "tplink_archer-c6-v3" {
		t.Fatalf("archer c6 v3: %+v", r)
	}
	if !strings.Contains(r.Matches[0].SelectorURL, "id=tplink_archer-c6-v3") {
		t.Fatal(r.Matches[0].SelectorURL)
	}
	if r := a.CheckModel("Archer C6"); len(r.Matches) != 2 { // C6 v2 and v3, not C60
		t.Fatalf("archer c6: %+v", r)
	}
	if r := a.CheckModel("archer c"); len(r.Matches) != 3 { // partial word: everything that fits
		t.Fatalf("archer c: %+v", r)
	}
	if r := a.CheckModel("ax3000t"); len(r.Matches) != 1 || !strings.Contains(r.Matches[0].Title, "Xiaomi") {
		t.Fatalf("ax3000t: %+v", r)
	}
	if r := a.CheckModel("Keenetic Giga"); len(r.Matches) != 0 || r.Error != "" {
		t.Fatalf("not supported: %+v", r)
	}

	dir := t.TempDir()
	good := filepath.Join(dir, "good.bin")
	os.WriteFile(good, image, 0o600)
	if c := checkImageFile(good, "tplink_archer-c6-v3", "ramips/mt7621"); !c.OK || c.Type != "factory" || !c.HasFactory {
		t.Fatalf("good image: %+v", c)
	}
	other := filepath.Join(dir, "other.bin")
	os.WriteFile(other, []byte("something else"), 0o600)
	if c := checkImageFile(other, "tplink_archer-c6-v3", "ramips/mt7621"); c.OK || c.Error != "" {
		t.Fatalf("foreign file: %+v", c)
	}
}

func TestReportOnFakeRouter(t *testing.T) {
	sh := fakessh.FindSh()
	if sh == "" {
		t.Skip("no POSIX sh")
	}
	repo, _ := filepath.Abs("..")
	work := t.TempDir()
	fake := filepath.Join(work, "opt")
	if err := fakessh.MakeFakeKeenetic(sh, repo, fake); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(fake, "rc.extra"), []byte("interface Wireguard0\n    wireguard private-key "+fakePriv+"\n!\n"), 0o600)
	host, port := serve(t, sh, []string{"SB_OPT=" + fakessh.PosixPath(fake), "SB_TEST=1", "SB_PLATFORM=keenetic"}, fakessh.NewKey())
	a := NewApp()
	a.kh = &knownHosts{path: filepath.Join(work, "known_hosts")}
	a.remoteDir = fakessh.PosixPath(filepath.Join(work, "remote"))
	a.emit = func(string, any) {}
	if r := a.Connect(host, port, "root", "secret"); !r.OK {
		t.Fatal(r.Error)
	}
	defer a.Disconnect()
	text, err := a.reportText()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(text, "ip route 91.108.56.0") || !strings.Contains(text, "Связь сейчас") {
		t.Fatalf("report misses parts:\n%s", text)
	}
	if strings.Contains(text, fakePriv) || strings.Contains(text, "@@sb") {
		t.Fatal("report holds a key or event lines")
	}
}

func TestNormSite(t *testing.T) {
	for in, want := range map[string]string{
		"https://www.Example.org/page?x=1": "example.org",
		"  sub.site.co.uk ":                "sub.site.co.uk",
		"example.org:8443":                 "example.org",
		"x.org;reboot":                     "",
		"localhost":                        "",
		"-bad.com":                         "",
		"a..b":                             "",
		"$(id).com":                        "",
	} {
		if got := normSite(in); got != want {
			t.Errorf("normSite(%q) = %q, want %q", in, got, want)
		}
	}
}

// own sites, update and tune through the window's methods, on the fake Keenetic
func TestSitesUpdateTuneOnFakeRouter(t *testing.T) {
	sh := fakessh.FindSh()
	if sh == "" {
		t.Skip("no POSIX sh")
	}
	repo, _ := filepath.Abs("..")
	work := t.TempDir()
	fake := filepath.Join(work, "opt")
	if err := fakessh.MakeFakeKeenetic(sh, repo, fake); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(fake, "dns-blocked.example"), []byte("10.1.1.1\n"), 0o644)
	host, port := serve(t, sh, []string{"SB_OPT=" + fakessh.PosixPath(fake), "SB_TEST=1", "SB_PLATFORM=keenetic"}, fakessh.NewKey())
	a := NewApp()
	a.kh = &knownHosts{path: filepath.Join(work, "known_hosts")}
	a.remoteDir = fakessh.PosixPath(filepath.Join(work, "remote"))
	a.emit = func(string, any) {}
	if r := a.Connect(host, port, "root", "secret"); !r.OK {
		t.Fatal(r.Error)
	}
	defer a.Disconnect()

	if r := a.SiteAdd("https://Blocked.example/x", "vpn"); !r.OK {
		t.Fatal("vpn site:", r.Error)
	}
	if r := a.SiteAdd("bad;site", "zapret"); r.OK || r.Error == "" {
		t.Fatal("odd input accepted")
	}
	s := a.Sites()
	if !s.OK || len(s.Sites) != 1 || s.Sites[0].Domain != "blocked.example" || s.Sites[0].Way != "vpn" {
		t.Fatalf("sites list: %+v", s)
	}
	if s.Tunnel != "Wireguard0" || !s.Zapret {
		t.Fatalf("ways offered: %+v", s)
	}
	if c := a.SiteCheck("blocked.example"); !c.OK || !c.Opens {
		t.Fatalf("check: %+v", c)
	}
	// the dns way needs a DNS server: refused with the installer's own words
	if r := a.SiteAdd("other.example", "dns"); !r.OK {
		t.Fatal("dns site (server of chatgpt.com):", r.Error)
	}
	if r := a.SiteDel("blocked.example"); !r.OK {
		t.Fatal("del:", r.Error)
	}
	if r := a.Update(); !r.OK {
		t.Fatal("update:", r.Error)
	}
	if b, _ := os.ReadFile(filepath.Join(fake, "etc", "switchback", "app", "VERSION")); strings.TrimSpace(string(b)) != appVersion {
		t.Fatalf("copy on the router: version %q, program %q", b, appVersion)
	}
	if r := a.Tune(true); r.OK || !strings.Contains(r.Error, "подбор ещё не делался") {
		t.Fatalf("undo without a tune: %+v", r)
	}
	// ways of their own for YouTube video servers: on writes the profile, off takes it away
	conf := filepath.Join(fake, "etc", "nfqws2", "nfqws2.conf")
	a.TuneVideo(false) // a fresh install may have put it there already
	if r := a.TuneVideo(true); !r.OK {
		t.Fatal("video ways on:", r.Error)
	}
	if b, _ := os.ReadFile(conf); !strings.Contains(string(b), "--hostlist-domains=googlevideo.com") {
		t.Fatal("video ways on: no profile in nfqws2.conf")
	}
	if r := a.TuneVideo(false); !r.OK {
		t.Fatal("video ways off:", r.Error)
	}
	if b, _ := os.ReadFile(conf); strings.Contains(string(b), "googlevideo.com") {
		t.Fatal("video ways off: the profile stayed")
	}
}

func TestRouterGuess(t *testing.T) {
	cases := []struct{ xml, firmware, query, model string }{
		{`<root><device><deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType><friendlyName>Keenetic Gateway</friendlyName><manufacturer>Keenetic Ltd.</manufacturer><modelName>Keenetic Gateway</modelName><modelNumber>KN-1710</modelNumber></device></root>`,
			"keenetic", "Keenetic Gateway KN-1710", "Keenetic Gateway KN-1710"},
		{`<root><device><friendlyName>Archer C6</friendlyName><manufacturer>TP-Link Corporation Limited</manufacturer><modelName>Archer C6</modelName><modelNumber>3.0</modelNumber></device></root>`,
			"other", "TP-Link Archer C6 3.0", "Archer C6 3.0"},
		{`<root><device><friendlyName>OpenWrt (192.168.1.1)</friendlyName><manufacturer>OpenWrt Project</manufacturer><modelName>Xiaomi AX3000T</modelName></device></root>`,
			"openwrt", "Xiaomi AX3000T", "Xiaomi AX3000T"},
	}
	for _, c := range cases {
		d, err := parseDescription(strings.NewReader(c.xml))
		if err != nil {
			t.Fatal(err)
		}
		g := guessFrom(d, "http://192.168.1.1:1900/rootDesc.xml")
		if g.Firmware != c.firmware || g.Query != c.query || g.Model != c.model || g.Address != "192.168.1.1" {
			t.Errorf("%s: got %+v", c.model, g)
		}
	}
	if localURL("http://8.8.8.8/x.xml", net.ParseIP("8.8.8.8")) || localURL("http://192.168.1.5/x", net.ParseIP("192.168.1.1")) ||
		!localURL("http://192.168.1.1:1900/r.xml", net.ParseIP("192.168.1.1")) {
		t.Error("only the answering device on a private address may be asked for its description")
	}
	if ssdpLocation("HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.1:1900/rootDesc.xml\r\n") != "http://192.168.1.1:1900/rootDesc.xml" {
		t.Error("LOCATION not read")
	}
}

func TestFirmwareHint(t *testing.T) {
	owCache.Lock()
	owCache.version, owCache.profiles = "25.12.6", []owProfile{{ID: "xiaomi_mi-router-ax3000t", Target: "mediatek/filogic"}}
	owCache.Unlock()
	defer func() { owCache.version, owCache.profiles = "", nil }()
	a := NewApp()
	h := a.FirmwareHint("openwrt", "24.10.4", "xiaomi,mi-router-ax3000t")
	if !h.Warn || !strings.Contains(h.Text, "25.12.6") || !strings.Contains(h.Text, "старшую версию") ||
		!strings.Contains(h.URL, "id=xiaomi_mi-router-ax3000t") || !strings.Contains(h.URL, "target=mediatek%2Ffilogic") {
		t.Fatalf("older OpenWrt: %+v", h)
	}
	if h := a.FirmwareHint("openwrt", "25.12.6", "x"); h.Text != "" {
		t.Fatalf("latest OpenWrt needs no hint: %+v", h)
	}
	if h := a.FirmwareHint("openwrt", "25.12.2", "unknown,board"); h.Text == "" || strings.Contains(h.Text, "старшую") || strings.Contains(h.URL, "id=") {
		t.Fatalf("minor update, unknown board: %+v", h)
	}
	if h := a.FirmwareHint("keenetic", "3.8.7", "Extra"); !strings.Contains(h.Text, "4.x") || h.Warn {
		t.Fatalf("KeeneticOS 3.x: %+v", h)
	}
	if h := a.FirmwareHint("keenetic", "4.2.1", "x"); h.Text != "" {
		t.Fatalf("KeeneticOS 4.x: %+v", h)
	}
}

func TestNtfy(t *testing.T) {
	a := NewApp()
	ch := a.NewNtfyChannel()
	if !ntfyRe.MatchString(ch) || !strings.HasPrefix(ch, "https://ntfy.sh/sb-") || len(ch) < 40 {
		t.Fatalf("channel: %s", ch)
	}
	if a.NewNtfyChannel() == ch {
		t.Fatal("channel names repeat")
	}
	var got, title string
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		got, title = r.URL.Path+" "+string(b), r.Header.Get("Title")
	}))
	defer srv.Close()
	old := ntfyClient
	ntfyClient = srv.Client()
	defer func() { ntfyClient = old }()
	if e := a.TestNtfy(srv.URL + "/sb-0123456789abcdef"); e != "" {
		t.Fatal(e)
	}
	if !strings.HasPrefix(got, "/sb-0123456789abcdef switchback:") || title != "switchback" {
		t.Fatalf("server got %q title %q", got, title)
	}
	if a.TestNtfy("https://ntfy.sh/short") == "" || a.TestNtfy("http://ntfy.sh/sb-0123456789abcdef") == "" {
		t.Fatal("bad channel accepted")
	}
}

func TestDNSPresetsAndCheck(t *testing.T) {
	a := NewApp()
	if k := a.DNSPresets("keenetic"); len(k) == 0 || k[0].Kind != "dot" || k[0].IP == "" {
		t.Fatalf("Keenetic presets: %+v", k)
	}
	if o := a.DNSPresets("openwrt"); len(o) == 0 || o[0].Kind != "doh" {
		t.Fatalf("OpenWrt presets: %+v", o)
	}
	// a node (the "site") and a DoH service that points the site at it
	node := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(403) }))
	defer node.Close()
	_, port, _ := net.SplitHostPort(node.Listener.Addr().String())
	doh := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q, _ := base64.RawURLEncoding.DecodeString(r.URL.Query().Get("dns"))
		ans := append(append([]byte{}, q...), 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 127, 0, 0, 1)
		ans[2], ans[3], ans[7] = 0x81, 0x80, 1 // a response with one answer
		w.Header().Set("Content-Type", "application/dns-message")
		w.Write(ans)
	}))
	defer doh.Close()
	oldPort, oldHTTP, oldIns := nodePort, dnsHTTP, dotInsecure
	nodePort, dnsHTTP, dotInsecure = port, doh.Client(), true
	defer func() { nodePort, dnsHTTP, dotInsecure = oldPort, oldHTTP, oldIns }()
	if c := a.CheckDNS("doh", "", "", doh.URL+"/dns-query", "claude"); !c.OK || c.Node != "127.0.0.1" {
		t.Fatalf("check: %+v", c)
	}
	if c := a.CheckDNS("doh", "", "", "http://x", "claude"); c.OK || c.Error == "" {
		t.Fatal("plain http accepted")
	}
	if c := a.CheckDNS("dot", "not-an-ip", "x", "", "chatgpt"); c.OK {
		t.Fatal("bad IP accepted")
	}
}

// Entware from the web interface: login (challenge), checks, "opkg disk", Entware's SSH, new root password
func TestKeeneticEntware(t *testing.T) {
	sh := fakessh.FindSh()
	if sh == "" {
		t.Skip("no POSIX sh")
	}
	var cmds []string
	const realm, chal = "Keenetic Extra", "ABCDEF"
	web := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/auth" && r.Method == "GET":
			w.Header().Set("X-NDM-Realm", realm)
			w.Header().Set("X-NDM-Challenge", chal)
			w.WriteHeader(401)
		case r.URL.Path == "/auth":
			var b map[string]string
			json.NewDecoder(r.Body).Decode(&b)
			m := md5.Sum([]byte("admin:" + realm + ":webpass"))
			s := sha256.Sum256([]byte(chal + hex.EncodeToString(m[:])))
			if b["login"] != "admin" || b["password"] != hex.EncodeToString(s[:]) {
				w.WriteHeader(401)
				return
			}
			http.SetCookie(w, &http.Cookie{Name: "s", Value: "1"})
		case r.URL.Path == "/rci/show/version":
			w.Write([]byte(`{"title":"3.8.7","arch":"mips","description":"Keenetic Extra (KN-1710)","components":"base,opkg,opkg-kmod-netfilter,storage"}`))
		case r.URL.Path == "/rci/show/media":
			w.Write([]byte(`{"Media0":{"name":"Media0","partition":{"label":"ENTWARE","fstype":"ext4","state":"MOUNTED"}}}`))
		case r.URL.Path == "/rci/":
			var b []map[string]string
			json.NewDecoder(r.Body).Decode(&b)
			cmds = append(cmds, b[0]["parse"])
			w.Write([]byte(`[{"parse":{"status":[{"status":"message","message":"ok"}]}}]`))
		}
	}))
	defer web.Close()
	host := strings.TrimPrefix(web.URL, "http://")
	a := NewApp()
	a.emit = func(string, any) {}
	if c := a.KeeneticCheck(host, "admin", "wrong"); c.OK {
		t.Fatal("a wrong password was accepted")
	}
	c := a.KeeneticCheck(host, "admin", "webpass")
	if !c.OK || c.Installer != "mipsel" || c.Label != "ENTWARE" || c.Installed || len(c.Missing) != 1 || c.Missing[0] != "Файловая система Ext" {
		t.Fatalf("check: %+v", c)
	}
	// Entware's SSH with the default password and a passwd that writes what it was given
	work := t.TempDir()
	bin := filepath.Join(work, "bin")
	os.MkdirAll(bin, 0o755)
	os.WriteFile(filepath.Join(bin, "passwd"), []byte("#!/bin/sh\nread a; read b; echo \"$a $b\" > \"$PWFILE\"\n"), 0o755)
	pwfile := fakessh.PosixPath(filepath.Join(work, "pw"))
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	defer ln.Close()
	go fakessh.Serve(ln, fakessh.NewKey(), "keenetic", sh, []string{"PATH=" + fakessh.PosixPath(bin) + ":/usr/bin:/bin", "PWFILE=" + pwfile})
	_, p, _ := net.SplitHostPort(ln.Addr().String())
	port, _ := strconv.Atoi(p)
	oldPorts, oldStep, oldWait, oldPause := entwarePorts, entwareStep, entwareWait, passwdPause
	oldCmd := passwdCmd
	passwdCmd = "sh " + fakessh.PosixPath(filepath.Join(bin, "passwd"))
	defer func() { passwdCmd = oldCmd }()
	entwarePorts, entwareStep, entwareWait, passwdPause = []int{port}, 100*time.Millisecond, 5*time.Second, 200*time.Millisecond
	defer func() { entwarePorts, entwareStep, entwareWait, passwdPause = oldPorts, oldStep, oldWait, oldPause }()
	r := a.InstallEntware("127.0.0.1", "admin", "webpass", "ENTWARE", "mipsel", "short")
	if r.OK {
		t.Fatal("a too short root password was accepted")
	}
	// the web interface answers on the test server's port, Entware's SSH on another one: same host name
	r = a.InstallEntware(host, "admin", "webpass", "ENTWARE", "mipsel", "Test-Root-Pw7")
	if !r.OK {
		t.Fatal(r.Error)
	}
	if !strings.Contains(strings.Join(cmds, "|"), "opkg disk ENTWARE:/ https://bin.entware.net/mipselsf-k3.4/installer/mipsel-installer.tar.gz|system configuration save") {
		t.Fatalf("commands: %q", cmds)
	}
	got, _ := os.ReadFile(filepath.Join(work, "pw"))
	if strings.TrimSpace(string(got)) != "Test-Root-Pw7 Test-Root-Pw7" {
		t.Fatalf("passwd got %q", got)
	}
}
