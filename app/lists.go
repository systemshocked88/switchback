package main

// "Обновить списки": the program downloads newer lists (networks, domains, zapret ways) from the repository,
// checks them and sends them to the router; the router itself goes nowhere for them.
//
// A release of the lists is lists/VERSION (a whole number that only grows), the list files, SHA256SUMS
// (sha256 of VERSION and of every list) and SHA256SUMS.sig (Ed25519 signature of SHA256SUMS, base64).
// The signing key is kept by the owner outside the repository (tools/lists-sign); only the public key is
// here. So a hacked GitHub or Codeberg account cannot hand out lists: without the signature nothing is taken.
// Every line is checked as well: networks, domains and ways of strict shapes; no wide or home networks.

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/crypto/ssh"
)

// listsPubKey: the public key that checks SHA256SUMS.sig, base64 of 32 bytes.
// The key pair was made on 2026-11-17 with the owner's consent (go run ./tools/lists-sign -genkey ...); the private
// part is kept outside the repository. An empty key would turn list updates off (the button says so).
const listsPubKey = "fgjImF30zRlPiU/cgKUcOQ9/V1L+3IN9EIXVNEmm7bQ="

// where the lists are taken from: GitHub first, then the spare copy on Codeberg (Forgejo "raw" address:
// /OWNER/REPO/raw/branch/BRANCH/PATH, checked on codeberg.org with README.md on 17.11.2026).
var listsSources = []string{
	"https://raw.githubusercontent.com/" + updateRepo + "/main/lists/",
	mirrorSite + mirrorRepo + "/raw/branch/main/lists/",
}

// the lists the router reads (lib/common.sh LISTS) and the most entries each kind may have
var listFiles = []string{"telegram.nets", "meta.nets", "google.nets", "meta.domains", "zapret.domains",
	"claude.domains", "chatgpt.domains", "ai-claude.domains", "ai-chatgpt.domains", "ai-claude-proxies.nets", "ai-chatgpt-proxies.nets", "tune.ways", "tune-video.ways"}

const listMaxBytes = 64 << 10

type listSet struct {
	Version int
	Files   map[string][]byte // VERSION, SHA256SUMS, SHA256SUMS.sig and every list
	Source  string
}

type ListsResult struct {
	OK      bool   `json:"ok"`
	Message string `json:"message"`
	Router  int    `json:"router"` // version on the router (0: the lists that came with switchback, or unknown)
	Latest  int    `json:"latest"`
	Prev    int    `json:"prev"` // the previous lists kept on the router ("Вернуть прежние"); 0: none
}

// ---------- download and checks ----------

func httpGet(url string) ([]byte, error) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "switchback")
	r, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer r.Body.Close()
	if r.StatusCode != 200 {
		return nil, fmt.Errorf("ответ %d", r.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(r.Body, listMaxBytes+1))
	if err == nil && len(b) > listMaxBytes {
		err = errors.New("слишком большой файл")
	}
	return b, err
}

// fetchLists takes the lists from the first source that gives a complete, signed, valid set.
func fetchLists(sources []string, pub ed25519.PublicKey, builtin map[string][]byte) (*listSet, error) {
	var errs []string
	for _, base := range sources {
		s, err := fetchFrom(base, pub, builtin)
		if err == nil {
			return s, nil
		}
		errs = append(errs, err.Error())
	}
	return nil, errors.New(strings.Join(errs, "; "))
}

func fetchFrom(base string, pub ed25519.PublicKey, builtin map[string][]byte) (*listSet, error) {
	host := base
	if i := strings.Index(base[strings.Index(base, "//")+2:], "/"); i > 0 {
		host = base[:strings.Index(base, "//")+2+i]
	}
	get := func(name string) ([]byte, error) {
		b, err := httpGet(base + name)
		if err != nil {
			return nil, fmt.Errorf("%s: %s — %v", host, name, err)
		}
		return b, nil
	}
	sums, err := get("SHA256SUMS")
	if err != nil {
		return nil, err
	}
	sig, err := get("SHA256SUMS.sig")
	if err != nil {
		return nil, err
	}
	if err := checkSig(pub, sums, sig); err != nil {
		return nil, fmt.Errorf("%s: %v", host, err)
	}
	want, err := parseSums(sums)
	if err != nil {
		return nil, fmt.Errorf("%s: %v", host, err)
	}
	s := &listSet{Files: map[string][]byte{"SHA256SUMS": sums, "SHA256SUMS.sig": sig}, Source: host}
	for _, name := range append([]string{"VERSION"}, listFiles...) {
		b, err := get(name)
		if err != nil {
			return nil, err
		}
		h := sha256.Sum256(b)
		if hex.EncodeToString(h[:]) != want[name] {
			return nil, fmt.Errorf("%s: %s не совпадает с подписанной суммой", host, name)
		}
		s.Files[name] = b
	}
	if s.Version, err = parseListsVersion(s.Files["VERSION"]); err != nil {
		return nil, fmt.Errorf("%s: %v", host, err)
	}
	for _, name := range listFiles {
		if err := checkList(name, s.Files[name], builtin[name]); err != nil {
			return nil, fmt.Errorf("%s: %v", host, err)
		}
	}
	return s, nil
}

func checkSig(pub ed25519.PublicKey, sums, sig []byte) error {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(sig)))
	if err != nil || len(raw) != ed25519.SignatureSize || len(pub) != ed25519.PublicKeySize ||
		!ed25519.Verify(pub, sums, raw) {
		return errors.New("подпись списков не подходит")
	}
	return nil
}

// parseSums: "HEX  NAME" lines (sha256sum format); VERSION and every list must be there, nothing else.
func parseSums(b []byte) (map[string]string, error) {
	allowed := map[string]bool{"VERSION": true}
	for _, n := range listFiles {
		allowed[n] = true
	}
	m := map[string]string{}
	for _, l := range strings.Split(strings.ReplaceAll(string(b), "\r", ""), "\n") {
		if l == "" {
			continue
		}
		f := strings.Fields(l)
		if len(f) != 2 || len(f[0]) != 64 || !allowed[strings.TrimPrefix(f[1], "*")] {
			return nil, fmt.Errorf("непонятная строка в SHA256SUMS: %.60q", l)
		}
		m[strings.TrimPrefix(f[1], "*")] = strings.ToLower(f[0])
	}
	for n := range allowed {
		if m[n] == "" {
			return nil, fmt.Errorf("в SHA256SUMS нет %s", n)
		}
	}
	return m, nil
}

func parseListsVersion(b []byte) (int, error) {
	s := strings.TrimSpace(string(b))
	n, err := strconv.Atoi(s)
	if err != nil || n <= 0 || len(s) > 9 {
		return 0, errors.New("непонятная версия списков")
	}
	return n, nil
}

// listEntries: the entries of a list file, as the router reads them (lib/common.sh list_lines)
func listEntries(b []byte) []string {
	var out []string
	for _, l := range strings.Split(string(b), "\n") {
		if i := strings.Index(l, "#"); i >= 0 {
			l = l[:i]
		}
		if l = strings.TrimSpace(l); l != "" {
			out = append(out, l)
		}
	}
	return out
}

var (
	reDomain  = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$`)
	reWayName = regexp.MustCompile(`^[a-z0-9][a-z0-9+_-]{0,40}$`)
	reStep    = regexp.MustCompile(`^[a-z][a-z0-9_]*(:[A-Za-z0-9_=,.+-]+)*$`)
)

// checkList: every line of a strict shape, not too many entries, not much shorter than the lists that came
// with this program (a list cut down to a couple of lines would quietly switch things off).
func checkList(name string, b, builtin []byte) error {
	// comments may have any text; the entries are matched by the strict shapes below
	if bytes.ContainsAny(b, "\r\x00") || !utf8.Valid(b) {
		return fmt.Errorf("%s: недопустимые знаки", name)
	}
	es := listEntries(b)
	max := 200
	if strings.HasSuffix(name, ".ways") {
		max = 40
	}
	if len(es) == 0 || len(es) > max {
		return fmt.Errorf("%s: %d строк — так не бывает", name, len(es))
	}
	if n := len(listEntries(builtin)); n > 0 && len(es)*2 < n {
		return fmt.Errorf("%s: строк %d, а было %d — подозрительно мало", name, len(es), n)
	}
	for _, e := range es {
		var err error
		switch {
		case strings.HasSuffix(name, ".nets"):
			err = checkNet(e)
		case strings.HasSuffix(name, ".domains"):
			if len(e) > 253 || !reDomain.MatchString(e) {
				err = errors.New("не похоже на домен")
			}
		case name == "tune.ways":
			n, steps, ok := strings.Cut(e, "|")
			if !ok || !reWayName.MatchString(n) {
				err = errors.New("нужно ИМЯ|ШАГИ")
			} else {
				err = checkSteps(steps)
			}
		default:
			err = checkSteps(e)
		}
		if err != nil {
			return fmt.Errorf("%s: %.60q — %v", name, e, err)
		}
	}
	return nil
}

func checkSteps(s string) error {
	f := strings.Split(s, " ")
	if len(f) == 0 || len(f) > 8 {
		return errors.New("непонятные шаги")
	}
	for _, st := range f {
		if len(st) > 200 || !reStep.MatchString(st) {
			return errors.New("непонятный шаг")
		}
	}
	return nil
}

// networks that must never go into the tunnel lists: the whole internet, home and service networks
var forbiddenNets = []string{"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
	"172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/3"}

// checkNet: A.B.C.D/NN or A.B.C.D/M.M.M.M, from /8 to /32, the address being the network itself, and not
// touching a forbidden network.
func checkNet(e string) error {
	addr, mask, ok := strings.Cut(e, "/")
	if !ok {
		return errors.New("нужно СЕТЬ/МАСКА")
	}
	a, ok := ip4(addr)
	if !ok {
		return errors.New("непонятный адрес")
	}
	var bits int
	if m, ok := ip4(mask); ok {
		bits = 0
		for bits < 32 && m&(1<<(31-bits)) != 0 {
			bits++
		}
		if bits < 32 && m<<bits != 0 {
			return errors.New("непонятная маска")
		}
	} else if n, err := strconv.Atoi(mask); err == nil && len(mask) <= 2 {
		bits = n
	} else {
		return errors.New("непонятная маска")
	}
	if bits < 8 || bits > 32 {
		return errors.New("слишком широкая сеть")
	}
	m := uint32(0xffffffff) << (32 - bits)
	if bits == 32 {
		m = 0xffffffff
	}
	if a&^m != 0 {
		return errors.New("адрес не начало сети")
	}
	for _, f := range forbiddenNets {
		fa, _ := ip4(f[:strings.Index(f, "/")])
		fb, _ := strconv.Atoi(f[strings.Index(f, "/")+1:])
		fm := uint32(0xffffffff) << (32 - fb)
		common := m
		if fm < m { // the wider of the two masks
			common = fm
		}
		if a&common == fa&common {
			return fmt.Errorf("пересекается с %s", f)
		}
	}
	return nil
}

func ip4(s string) (uint32, bool) {
	p := strings.Split(s, ".")
	if len(p) != 4 {
		return 0, false
	}
	var v uint32
	for _, x := range p {
		n, err := strconv.Atoi(x)
		if err != nil || n < 0 || n > 255 || len(x) > 3 || (len(x) > 1 && x[0] == '0') {
			return 0, false
		}
		v = v<<8 | uint32(n)
	}
	return v, true
}

// builtinLists: the lists inside this program's installer archive (lib/common.sh reads the same files)
func builtinLists() map[string][]byte {
	m := map[string][]byte{}
	zr, err := gzip.NewReader(bytes.NewReader(installerTar))
	if err != nil {
		return m
	}
	tr := tar.NewReader(zr)
	for {
		h, err := tr.Next()
		if err != nil {
			return m
		}
		if name, ok := strings.CutPrefix(strings.TrimPrefix(h.Name, "./"), "lists/"); ok && h.Size <= listMaxBytes {
			b, _ := io.ReadAll(tr)
			m[name] = b
		}
	}
}

// ---------- to the router ----------

// listsTar: the set as tar.gz, for "install.sh lists put" on the router
func listsTar(s *listSet) []byte {
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	tw := tar.NewWriter(zw)
	for _, name := range append([]string{"VERSION", "SHA256SUMS", "SHA256SUMS.sig"}, listFiles...) {
		b := s.Files[name]
		tw.WriteHeader(&tar.Header{Name: name, Mode: 0644, Size: int64(len(b)), ModTime: time.Unix(0, 0), Typeflag: tar.TypeReg})
		tw.Write(b)
	}
	tw.Close()
	zw.Close()
	return buf.Bytes()
}

// pushLists sends the set to the router: "install.sh lists put" keeps the old lists in lists.prev, puts the
// new ones into switchback's copy and applies them. Returns the router's exit code.
func pushLists(c *ssh.Client, dir string, s *listSet, onLine func(string)) (int, error) {
	return runStream(c, "sh "+shellQuote(dir+"/install.sh")+" lists put --progress", bytes.NewReader(listsTar(s)), onLine)
}

// routerLists: "install.sh lists" on the router -> the version there (0: the built-in lists) and the version
// of the previous lists kept for "lists restore" (0: none)
func (a *App) routerLists() (int, int, error) {
	evs, _, err := a.runQuick("lists")
	if err != nil {
		return 0, 0, err
	}
	cur, prev := listsEvent(evs)
	return cur, prev, nil
}

func (a *App) routerListsVersion() (int, error) {
	n, _, err := a.routerLists()
	return n, err
}

// listsEvent: "@@sb lists CUR [PREV]"
func listsEvent(evs []sbEvent) (cur, prev int) {
	for _, e := range evs {
		if e.Kind == "lists" && len(e.Fields) > 0 {
			cur, _ = strconv.Atoi(e.Fields[0])
			if len(e.Fields) > 1 {
				prev, _ = strconv.Atoi(e.Fields[1])
			}
		}
	}
	return
}

// ListsVersion: the line "Списки: версия N" (N on the router).
func (a *App) ListsVersion() ListsResult {
	n, p, err := a.routerLists()
	if err != nil {
		return ListsResult{Message: err.Error()}
	}
	return ListsResult{OK: true, Router: n, Prev: p}
}

// RestoreLists: the button «Вернуть прежние» — "install.sh lists restore" puts the previous lists back (the
// newer ones are kept in their place, so pressing it again returns them).
func (a *App) RestoreLists() ListsResult {
	evs, _, err := a.runQuick("lists restore")
	if err != nil {
		return ListsResult{Message: err.Error()}
	}
	return restoreResult(evs)
}

func restoreResult(evs []sbEvent) ListsResult {
	for _, e := range evs {
		if e.Kind != "lists_restored" || len(e.Fields) == 0 {
			continue
		}
		switch e.Fields[0] {
		case "none":
			return ListsResult{Message: "Прежних списков на роутере нет — возвращать нечего."}
		case "fail":
			return ListsResult{Message: "Вернуть прежние списки не получилось — остались новые. Подробности в журнале."}
		}
		n, _ := strconv.Atoi(e.Fields[0])
		return ListsResult{OK: true, Router: n, Prev: 1, Message: fmt.Sprintf("Прежние списки возвращены (версия %d).", n)}
	}
	return ListsResult{Message: "Роутер не сообщил, вернулись ли списки. Подробности в журнале."}
}

// putMessage: what the window says after "lists put" with a non-zero exit code
func putMessage(rollback string) string {
	switch rollback {
	case "":
		return "Роутер не принял списки — прежние остались. Подробности в журнале."
	case "fail":
		return "Новые списки не подошли, а вернуть прежние роутер сам не смог. Нажмите «Вернуть прежние»."
	}
	return "С новыми списками стало хуже, поэтому роутер сам вернул прежние (версия " + rollback + "). Подробности в журнале."
}

// UpdateLists: the button «Обновить списки».
func (a *App) UpdateLists() ListsResult {
	if listsPubKey == "" {
		return ListsResult{Message: "Обновления списков ещё не включены."}
	}
	pub, err := base64.StdEncoding.DecodeString(listsPubKey)
	if err != nil {
		return ListsResult{Message: "Обновления списков ещё не включены."}
	}
	return a.updateLists(listsSources, ed25519.PublicKey(pub))
}

func (a *App) updateLists(sources []string, pub ed25519.PublicKey) ListsResult {
	a.mu.Lock()
	c := a.client
	a.mu.Unlock()
	if c == nil {
		return ListsResult{Message: "Нет подключения к роутеру."}
	}
	cur, err := a.routerListsVersion() // also puts a fresh installer into remoteDir
	if err != nil {
		return ListsResult{Message: err.Error()}
	}
	s, err := fetchLists(sources, pub, builtinLists())
	if err != nil {
		return ListsResult{Router: cur, Message: "Не удалось получить списки: " + err.Error()}
	}
	if s.Version <= cur {
		return ListsResult{OK: true, Router: cur, Latest: s.Version, Message: fmt.Sprintf("Списки уже свежие (версия %d).", cur)}
	}
	a.emit("sb:log", fmt.Sprintf("Списки версии %d взяты с %s, подпись верна; отправляю на роутер", s.Version, s.Source))
	rollback := ""
	code, err := pushLists(c, a.remoteDir, s, func(l string) {
		if ev, ok := parseEvent(l); ok {
			if ev.Kind == "lists_rollback" && len(ev.Fields) > 0 {
				rollback = ev.Fields[0]
			}
			a.emit("sb:event", ev)
		} else {
			a.emit("sb:log", l)
		}
	})
	if err != nil {
		return ListsResult{Router: cur, Latest: s.Version, Message: fmt.Sprintf("Связь с роутером оборвалась: %v", err)}
	}
	if code != 0 {
		return ListsResult{Router: cur, Latest: s.Version, Prev: 1, Message: putMessage(rollback)}
	}
	return ListsResult{OK: true, Router: s.Version, Latest: s.Version, Prev: cur + 1, Message: fmt.Sprintf("Списки обновлены до версии %d.", s.Version)}
}
