package main

import (
	"compress/gzip"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"switchback/internal/fakessh"
)

const fakeToken = "123456789:AAFakeTokenForTestsOnly_abcdefghijklmnop"

func TestBuildAnswers(t *testing.T) {
	s, err := buildAnswers(map[string]string{"profile": "full", "vpn_iface": " Wireguard0 "})
	if err != nil || s != "profile=full\nvpn_iface=Wireguard0\n" {
		t.Fatalf("got %q %v", s, err)
	}
	if _, err := buildAnswers(map[string]string{"profle": "x"}); err == nil {
		t.Fatal("unknown key accepted")
	}
	if _, err := buildAnswers(map[string]string{"bot_token": "a\nprofile=full"}); err == nil {
		t.Fatal("multi-line value accepted")
	}
}

func TestInstallOnFakeRouter(t *testing.T) {
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
	count := func(kind string) int {
		n := 0
		for _, e := range evs {
			if e.Kind == kind {
				n++
			}
		}
		return n
	}
	runLog := filepath.Join(work, "remote", "run.log")

	// analysis reports the platform and the VPN connections for the settings screen
	a.Analyze()
	var platform, vpn, tgvia string
	for _, e := range evs {
		switch e.Kind {
		case "platform":
			platform = e.Fields[0]
		case "vpn":
			vpn += strings.Join(e.Fields, ":") + " "
		case "tgvia":
			tgvia = e.Fields[0]
		}
	}
	if platform != "keenetic" || vpn != "Wireguard0:up Wireguard1:down " || tgvia != "Wireguard0" {
		t.Fatalf("platform=%q vpn=%q tgvia=%q", platform, vpn, tgvia)
	}

	// dry run, full profile: 5 steps, nothing changed, token never in the log, answers file gone
	evs = nil
	full := map[string]string{"profile": "full", "dns_claude": "y", "dns_claude_ip": "5.6.7.8",
		"dns_claude_sni": "dns.claude.example", "vpn_iface": "Wireguard0", "bot_token": fakeToken, "bot_chat": "-100"}
	r := a.Install(full, true)
	if !r.OK || count("step") != 8 {
		t.Fatalf("dry run: %+v steps=%d\n%s", r, count("step"), strings.Join(logs, "\n"))
	}
	if _, err := os.Stat(filepath.Join(work, "remote", "answers")); err == nil {
		t.Fatal("answers file left on the router")
	}
	if b, _ := os.ReadFile(runLog); strings.Contains(string(b), fakeToken) {
		t.Fatal("token in run.log")
	}
	if _, err := os.Stat(filepath.Join(fake, "etc", "switchback", "state")); err == nil {
		t.Fatal("dry run changed the router")
	}

	// real install of two modules, then the snapshot is downloaded to the PC
	evs = nil
	r = a.Install(map[string]string{"profile": "custom", "modules": "zapret dns", "dns_claude": "y",
		"dns_claude_ip": "5.6.7.8", "dns_claude_sni": "dns.claude.example"}, false)
	if !r.OK || r.Backup == "" || count("result") != 2 {
		t.Fatalf("install: %+v results=%d\n%s", r, count("result"), strings.Join(logs, "\n"))
	}
	ndm, _ := os.ReadFile(filepath.Join(fake, "ndmc.log"))
	if !strings.Contains(string(ndm), "domain claude.ai") {
		t.Fatal("DNS was not set on the fake router")
	}
	out := filepath.Join(work, "snapshot.tar.gz")
	if err := a.downloadBackup(r.Backup, out); err != nil {
		t.Fatal(err)
	}
	f, _ := os.Open(out)
	if _, err := gzip.NewReader(f); err != nil {
		t.Fatalf("snapshot is not a gzip archive: %v", err)
	}
	f.Close()
	if err := a.downloadBackup("/etc/passwd", out); err == nil {
		t.Fatal("downloaded a path outside the snapshot folders")
	}

	// the router refuses a setting midway: error shown, the run rolled back by itself
	evs = nil
	r = a.Install(map[string]string{"profile": "full", "dns_claude": "y", "dns_claude_ip": "9.9.9.9",
		"dns_claude_sni": "bad.example", "vpn_iface": "Wireguard0"}, false)
	if r.OK || !strings.Contains(r.Error, "claude.ai") {
		t.Fatalf("failure not reported: %+v", r)
	}
	if count("fail") != 1 {
		t.Fatal("no fail event")
	}
}

func TestCheckBot(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case !strings.Contains(r.URL.Path, fakeToken):
			w.Write([]byte(`{"ok":false}`))
		case strings.HasSuffix(r.URL.Path, "/getMe"):
			w.Write([]byte(`{"ok":true,"result":{"username":"my_router_bot"}}`))
		case strings.HasSuffix(r.URL.Path, "/getUpdates"):
			w.Write([]byte(`{"ok":true,"result":[{"message":{"chat":{"id":111}}},{"message":{"chat":{"id":222}}}]}`))
		}
	}))
	defer srv.Close()
	old := telegramAPI
	telegramAPI = srv.URL
	defer func() { telegramAPI = old }()

	a := NewApp()
	if r := a.CheckBot("not a token"); r.OK {
		t.Fatal("garbage accepted")
	}
	if r := a.CheckBot(" " + fakeToken + " "); !r.OK || r.Username != "my_router_bot" || r.Chat != "222" {
		t.Fatalf("got %+v", r)
	}
	if r := a.CheckBot("123456789:AAAnotherTokenThatTelegramRejects_xyz"); r.OK {
		t.Fatal("rejected token reported OK")
	}
}
