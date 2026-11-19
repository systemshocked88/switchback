package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"switchback/internal/fakessh"
)

// signedSet: the repository's lists with VERSION v, summed and signed with priv (a throwaway test key)
func signedSet(t *testing.T, priv ed25519.PrivateKey, v int) map[string][]byte {
	t.Helper()
	files := map[string][]byte{"VERSION": []byte(fmt.Sprintf("%d\n", v))}
	for _, n := range listFiles {
		b, err := os.ReadFile(filepath.Join("..", "lists", n))
		if err != nil {
			t.Fatal(err)
		}
		files[n] = b
	}
	resign(files, priv)
	return files
}

func resign(files map[string][]byte, priv ed25519.PrivateKey) {
	var names []string
	for n := range files {
		if !strings.HasPrefix(n, "SHA256SUMS") {
			names = append(names, n)
		}
	}
	sort.Strings(names)
	var sb strings.Builder
	for _, n := range names {
		h := sha256.Sum256(files[n])
		fmt.Fprintf(&sb, "%s  %s\n", hex.EncodeToString(h[:]), n)
	}
	files["SHA256SUMS"] = []byte(sb.String())
	files["SHA256SUMS.sig"] = []byte(base64.StdEncoding.EncodeToString(ed25519.Sign(priv, files["SHA256SUMS"])) + "\n")
}

// listServer: a local stand-in for GitHub raw or Codeberg; status != 200 answers every request with it
func listServer(t *testing.T, files map[string][]byte, status *int) *httptest.Server {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if *status != 200 {
			w.WriteHeader(*status)
			return
		}
		b, ok := files[strings.TrimPrefix(r.URL.Path, "/lists/")]
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Write(b)
	}))
	t.Cleanup(s.Close)
	return s
}

func TestFetchLists(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	otherPub, otherPriv, _ := ed25519.GenerateKey(rand.Reader)
	builtin := builtinLists()
	if len(builtin["telegram.nets"]) == 0 {
		t.Fatal("the installer archive has no lists: run `go generate`")
	}
	ghFiles, cbFiles := signedSet(t, priv, 5), signedSet(t, priv, 5)
	ghStatus, cbStatus := 200, 200
	gh, cb := listServer(t, ghFiles, &ghStatus), listServer(t, cbFiles, &cbStatus)
	src := []string{gh.URL + "/lists/", cb.URL + "/lists/"}

	s, err := fetchLists(src, pub, builtin)
	if err != nil || s.Version != 5 || s.Source != gh.URL {
		t.Fatalf("a good set from the first source: %+v %v", s, err)
	}

	// GitHub answers with an error: the spare copy on Codeberg is used
	ghStatus = 500
	if s, err = fetchLists(src, pub, builtin); err != nil || s.Source != cb.URL {
		t.Fatalf("fallback to the second source: %+v %v", s, err)
	}
	ghStatus = 200

	// signed with another key: refused everywhere
	if _, err := fetchLists(src, otherPub, builtin); err == nil || !strings.Contains(err.Error(), "подпись") {
		t.Fatalf("a wrong key must be refused: %v", err)
	}
	resign(ghFiles, otherPriv)
	if s, err = fetchLists(src, pub, builtin); err != nil || s.Source != cb.URL {
		t.Fatalf("a set signed by someone else must be skipped: %+v %v", s, err)
	}

	// a list changed after signing: the sum does not match
	ghFiles = signedSet(t, priv, 6)
	ghFiles["telegram.nets"] = append(ghFiles["telegram.nets"], []byte("8.8.8.0/24\n")...)
	gh2 := listServer(t, ghFiles, &ghStatus)
	if _, err := fetchLists([]string{gh2.URL + "/lists/"}, pub, builtin); err == nil || !strings.Contains(err.Error(), "не совпадает") {
		t.Fatalf("a changed file must be refused: %v", err)
	}

	// signed, but a home network inside: refused by the line check
	bad := signedSet(t, priv, 7)
	bad["telegram.nets"] = append(bad["telegram.nets"], []byte("192.168.1.0/24\n")...)
	resign(bad, priv)
	gh3 := listServer(t, bad, &ghStatus)
	if _, err := fetchLists([]string{gh3.URL + "/lists/"}, pub, builtin); err == nil || !strings.Contains(err.Error(), "192.168") {
		t.Fatalf("a signed list with a home network must be refused: %v", err)
	}

	// an extra file in SHA256SUMS: refused
	extra := signedSet(t, priv, 8)
	extra["evil.sh"] = []byte("rm -rf /\n")
	resign(extra, priv)
	gh4 := listServer(t, extra, &ghStatus)
	if _, err := fetchLists([]string{gh4.URL + "/lists/"}, pub, builtin); err == nil {
		t.Fatal("an unknown file in SHA256SUMS must be refused")
	}
}

func TestCheckNet(t *testing.T) {
	for _, c := range []struct {
		net string
		ok  bool
	}{
		{"91.108.4.0/22", true},
		{"91.108.56.0/255.255.252.0", true},
		{"149.154.160.0/20", true},
		{"8.8.8.8/32", true},
		{"0.0.0.0/0", false},
		{"0.0.0.0/8", false},
		{"64.0.0.0/2", false},
		{"10.0.0.0/8", false},
		{"10.1.2.0/24", false},
		{"172.20.0.0/16", false},
		{"192.168.0.0/16", false},
		{"192.0.0.0/8", false}, // holds 192.168/16
		{"100.64.0.0/10", false},
		{"127.0.0.1/32", false},
		{"230.0.0.0/8", false},
		{"91.108.4.1/22", false}, // not the start of the network
		{"91.108.4.0/255.0.255.0", false},
		{"91.108.4.0/33", false},
		{"91.108.04.0/22", false},
		{"91.108.4.0", false},
		{"91.108.4.0/22; reboot", false},
	} {
		if err := checkNet(c.net); (err == nil) != c.ok {
			t.Errorf("checkNet(%q) = %v, want ok=%v", c.net, err, c.ok)
		}
	}
}

func TestCheckList(t *testing.T) {
	builtin := builtinLists()
	for name, b := range builtin {
		if strings.Contains(name, ".") && name != "SHA256SUMS.sig" && contains(listFiles, name) {
			if err := checkList(name, b, b); err != nil {
				t.Errorf("the repository's own %s must pass: %v", name, err)
			}
		}
	}
	for _, c := range []struct{ name, body string }{
		{"claude.domains", "claude.ai\nexample.com; reboot\n"},
		{"claude.domains", "Claude.AI\n"},
		{"claude.domains", "-bad.com\n"},
		{"claude.domains", "# only a comment\n"},
		{"tune.ways", "x|fake:blob=a $(reboot)\n"},
		{"tune.ways", "no-steps\n"},
		{"tune.ways", "x|fake:a=1`id`\n"},
		{"tune-video.ways", "fake:a=1|b\n"},
		{"meta.domains", "instagram.com\r\n"},
	} {
		if err := checkList(c.name, []byte(c.body), nil); err == nil {
			t.Errorf("%s %q must be refused", c.name, c.body)
		}
	}
	// much shorter than the built-in list: refused
	if err := checkList("telegram.nets", []byte("91.108.4.0/22\n"), builtin["telegram.nets"]); err == nil {
		t.Error("a list cut to one line must be refused")
	}
}

func contains(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

// The set goes to the router as tar.gz on the stdin of "install.sh lists put". The "router" is the fake SSH
// server with a stand-in install.sh written here: it only saves what it gets and answers with an event.
// No system command is run by bare name besides sh and cat inside a temporary folder.
func TestPushLists(t *testing.T) {
	sh := fakessh.FindSh()
	if sh == "" {
		t.Skip("no POSIX sh")
	}
	work := t.TempDir()
	remote := filepath.Join(work, "remote")
	os.MkdirAll(remote, 0755)
	os.WriteFile(filepath.Join(remote, "install.sh"), []byte(
		"[ \"$1 $2\" = \"lists put\" ] || exit 9\ncat > \"$(dirname \"$0\")/got.tgz\"\nprintf '@@sb\\tlists_applied\\t5\\n'\n"), 0644)
	host, port := serve(t, sh, nil, fakessh.NewKey())
	c, _, err := dialRouter(host, port, "root", "secret", &knownHosts{path: filepath.Join(work, "known_hosts")})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s := &listSet{Version: 5, Files: signedSet(t, priv, 5)}
	var evs []sbEvent
	code, err := pushLists(c, fakessh.PosixPath(remote), s, func(l string) {
		if e, ok := parseEvent(l); ok {
			evs = append(evs, e)
		}
	})
	if err != nil || code != 0 {
		t.Fatalf("push: code %d, %v", code, err)
	}
	if len(evs) != 1 || evs[0].Kind != "lists_applied" {
		t.Fatalf("events: %v", evs)
	}
	b, err := os.ReadFile(filepath.Join(remote, "got.tgz"))
	if err != nil {
		t.Fatal(err)
	}
	zr, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	tr := tar.NewReader(zr)
	got := map[string][]byte{}
	for {
		h, err := tr.Next()
		if err != nil {
			break
		}
		got[h.Name], _ = io.ReadAll(tr)
	}
	for _, n := range append([]string{"VERSION", "SHA256SUMS", "SHA256SUMS.sig"}, listFiles...) {
		if !bytes.Equal(got[n], s.Files[n]) {
			t.Errorf("%s did not arrive as sent", n)
		}
	}
}

func TestUpdateListsOff(t *testing.T) {
	if listsPubKey == "" {
		if r := NewApp().UpdateLists(); r.OK || !strings.Contains(r.Message, "ещё не включены") {
			t.Fatalf("without a key the button must say updates are off: %+v", r)
		}
	}
}

func TestListsRestoreEvents(t *testing.T) {
	ev := func(k string, f ...string) []sbEvent { return []sbEvent{{Kind: k, Fields: f}} }
	if c, p := listsEvent(ev("lists", "10", "11")); c != 10 || p != 11 {
		t.Errorf("lists 10 11 -> %d %d", c, p)
	}
	if c, p := listsEvent(ev("lists", "7")); c != 7 || p != 0 {
		t.Errorf("old router (one field) -> %d %d", c, p)
	}
	if r := restoreResult(ev("lists_restored", "10")); !r.OK || r.Router != 10 || !strings.Contains(r.Message, "возвращены") {
		t.Errorf("restored: %+v", r)
	}
	if r := restoreResult(ev("lists_restored", "none")); r.OK || !strings.Contains(r.Message, "нечего") {
		t.Errorf("nothing to restore: %+v", r)
	}
	if r := restoreResult(ev("lists_restored", "fail")); r.OK || !strings.Contains(r.Message, "не получилось") {
		t.Errorf("restore failed: %+v", r)
	}
	if r := restoreResult(nil); r.OK {
		t.Errorf("no answer is not success: %+v", r)
	}
	if m := putMessage("10"); !strings.Contains(m, "сам вернул прежние (версия 10)") {
		t.Errorf("rollback message: %s", m)
	}
	if m := putMessage(""); !strings.Contains(m, "прежние остались") {
		t.Errorf("refused message: %s", m)
	}
}

func TestRestoreListsButton(t *testing.T) {
	b, err := os.ReadFile("frontend/dist/index.html")
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range []string{`id="btn-lists-back"`, ">Вернуть прежние<", "App().RestoreLists()"} {
		if !bytes.Contains(b, []byte(s)) {
			t.Errorf("the window has no %s", s)
		}
	}
}
