package main

// End-to-end test without a router: an in-process SSH server (internal/fakessh) runs the
// program's commands with the local POSIX shell against the fake Keenetic from tests/.

import (
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"

	"switchback/internal/fakessh"
)

func TestParseEvent(t *testing.T) {
	ev, ok := parseEvent("@@sb\titem\tok\tпамяти 128 МБ")
	if !ok || ev.Kind != "item" || len(ev.Fields) != 2 || ev.Fields[1] != "памяти 128 МБ" {
		t.Fatalf("bad parse: %+v %v", ev, ok)
	}
	if _, ok := parseEvent("  [ok] обычная строка"); ok {
		t.Fatal("plain line parsed as event")
	}
}

func TestInstallerBundled(t *testing.T) {
	if len(installerTar) < 1000 {
		t.Fatal("installer archive is empty: run `go generate`")
	}
}

// serve starts a fake router with key and returns its host and port.
func serve(t *testing.T, sh string, env []string, key ssh.Signer) (string, int) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go fakessh.Serve(ln, key, "secret", sh, env)
	h, p, _ := net.SplitHostPort(ln.Addr().String())
	port, _ := strconv.Atoi(p)
	return h, port
}

func TestConnectAndAnalyze(t *testing.T) {
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
	env := []string{"SB_OPT=" + fakessh.PosixPath(fake), "SB_TEST=1", "SB_PLATFORM=keenetic"}
	host, port := serve(t, sh, env, fakessh.NewKey())

	newApp := func() (*App, *[]sbEvent, *[]string) {
		a := NewApp()
		a.kh = &knownHosts{path: filepath.Join(work, "known_hosts")}
		a.remoteDir = fakessh.PosixPath(filepath.Join(work, "remote"))
		var evs []sbEvent
		var logs []string
		a.emit = func(name string, data any) {
			switch name {
			case "sb:event":
				evs = append(evs, data.(sbEvent))
			case "sb:log":
				logs = append(logs, data.(string))
			}
		}
		return a, &evs, &logs
	}

	// wrong password
	a, _, _ := newApp()
	if r := a.Connect(host, port, "root", "wrong"); r.OK || !strings.Contains(r.Error, "пароль") {
		t.Fatalf("wrong password accepted or bad message: %+v", r)
	}

	// first connection: key remembered; analysis streams events
	a, evs, logs := newApp()
	first := a.Connect(host, port, "root", "secret")
	if !first.OK || !first.NewKey || !strings.HasPrefix(first.Fingerprint, "SHA256:") {
		t.Fatalf("connect: %+v", first)
	}
	res := a.Analyze()
	a.Disconnect()
	if !res.OK {
		t.Fatalf("analyze: %+v\nlog:\n%s", res, strings.Join(*logs, "\n"))
	}
	var verdict, end bool
	items := 0
	for _, e := range *evs {
		switch e.Kind {
		case "doctor":
			verdict = true
		case "end":
			end = true
		case "item":
			items++
		}
	}
	if !verdict || !end || items < 5 {
		t.Fatalf("events: doctor=%v end=%v items=%d\n%v", verdict, end, items, *evs)
	}
	if _, err := os.Stat(filepath.Join(work, "remote", "lib", "doctor.sh")); err != nil {
		t.Fatal("installer was not unpacked on the 'router'")
	}
	if _, err := os.Stat(filepath.Join(work, "remote", "lists", "telegram.nets")); err != nil {
		t.Fatal("the lists did not come with the installer")
	}

	// installer fails on the router (no Entware): an error, not "warnings" (both exit 1)
	a, _, _ = newApp()
	os.Rename(filepath.Join(fake, "etc"), filepath.Join(fake, "etc.off"))
	a.Connect(host, port, "root", "secret")
	if res := a.Analyze(); res.OK || !strings.Contains(res.Error, "Entware") {
		t.Fatalf("failure reported as success: %+v", res)
	}
	a.Disconnect()
	os.Rename(filepath.Join(fake, "etc.off"), filepath.Join(fake, "etc"))

	// second connection: same key, not new
	a, _, _ = newApp()
	if r := a.Connect(host, port, "root", "secret"); !r.OK || r.NewKey {
		t.Fatalf("second connect: %+v", r)
	}
	a.Disconnect()

	// the router's key changes (reset or impostor): refused until forgotten
	host2, port2 := serve(t, sh, env, fakessh.NewKey())
	a, _, _ = newApp()
	a.kh.remember(net.JoinHostPort(host2, strconv.Itoa(port2)), first.Fingerprint) // "we saw another key here"
	if r := a.Connect(host2, port2, "root", "secret"); r.OK || !r.KeyChanged {
		t.Fatalf("changed key accepted: %+v", r)
	}
	a.ForgetKey(host2, port2)
	if r := a.Connect(host2, port2, "root", "secret"); !r.OK || !r.NewKey {
		t.Fatalf("after forget: %+v", r)
	}
	a.Disconnect()
}
