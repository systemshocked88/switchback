package main

// Entware on a Keenetic / Netcraze without the command line: the program talks to the router's web interface
// (the same API the web console http://192.168.1.1/a uses, login admin), checks the components and the USB
// stick, starts "opkg disk LABEL:/ INSTALLER-URL" (the router downloads and installs Entware itself), waits
// for Entware's SSH to come up and replaces the default root password "keenetic" with the user's own.
// Formatting the stick (ext4) stays manual: writing to a disk from Windows risks wiping the wrong one.

import (
	"bytes"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

type kRCI struct {
	base string
	cl   *http.Client
}

// kLogin: the web interface's challenge login (realm and challenge from /auth, then
// sha256(challenge + md5(login:realm:password))).
func kLogin(host, login, password string) (*kRCI, error) {
	jar, _ := cookiejar.New(nil)
	k := &kRCI{base: "http://" + host, cl: &http.Client{Timeout: 15 * time.Second, Jar: jar}}
	r, err := k.cl.Get(k.base + "/auth")
	if err != nil {
		return nil, fmt.Errorf("роутер не ответил по адресу %s", host)
	}
	r.Body.Close()
	if r.StatusCode == 200 {
		return k, nil // already logged in (a session cookie)
	}
	realm, chal := r.Header.Get("X-NDM-Realm"), r.Header.Get("X-NDM-Challenge")
	if realm == "" || chal == "" {
		return nil, fmt.Errorf("это не похоже на веб-интерфейс Keenetic/Netcraze")
	}
	m := md5.Sum([]byte(login + ":" + realm + ":" + password))
	s := sha256.Sum256([]byte(chal + hex.EncodeToString(m[:])))
	body, _ := json.Marshal(map[string]string{"login": login, "password": hex.EncodeToString(s[:])})
	r, err = k.cl.Post(k.base+"/auth", "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	r.Body.Close()
	if r.StatusCode != 200 {
		return nil, fmt.Errorf("роутер не принял логин и пароль веб-интерфейса")
	}
	return k, nil
}

func (k *kRCI) get(path string, v any) error {
	r, err := k.cl.Get(k.base + "/rci/" + path)
	if err != nil {
		return err
	}
	defer r.Body.Close()
	if r.StatusCode != 200 {
		return fmt.Errorf("роутер ответил %d на %s", r.StatusCode, path)
	}
	return json.NewDecoder(io.LimitReader(r.Body, 4<<20)).Decode(v)
}

// parse runs one CLI command (like the web console) and returns its messages.
func (k *kRCI) parse(cmd string) (string, error) {
	body, _ := json.Marshal([]map[string]string{{"parse": cmd}})
	r, err := k.cl.Post(k.base+"/rci/", "application/json", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	defer r.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	var res []map[string]any
	if json.Unmarshal(b, &res) != nil || len(res) == 0 {
		return string(b), nil
	}
	var msgs []string
	var walk func(any)
	walk = func(v any) {
		switch t := v.(type) {
		case map[string]any:
			if m, ok := t["message"].(string); ok {
				if st, _ := t["status"].(string); st == "error" {
					msgs = append(msgs, "ошибка: "+m)
				} else {
					msgs = append(msgs, m)
				}
			} else if lines, ok := t["message"].([]any); ok { // e.g. "show running-config": one string per line
				for _, l := range lines {
					if s, ok := l.(string); ok {
						msgs = append(msgs, s)
					}
				}
			}
			for _, x := range t {
				walk(x)
			}
		case []any:
			for _, x := range t {
				walk(x)
			}
		}
	}
	walk(res[0])
	out := strings.Join(msgs, "; ")
	if strings.Contains(out, "ошибка: ") {
		return out, fmt.Errorf("%s", out)
	}
	return out, nil
}

// KeeneticCheck goes back to the window.
type KeeneticCheck struct {
	OK        bool     `json:"ok"`
	Error     string   `json:"error"`
	Model     string   `json:"model"`
	Firmware  string   `json:"firmware"`
	Arch      string   `json:"arch"`      // what the router says: mips / aarch64
	Installer string   `json:"installer"` // the suggested Entware installer (mipsel / mips / aarch64)
	Missing   []string `json:"missing"`   // components to turn on first
	Label     string   `json:"label"`     // the ext4 stick's label ("" = no suitable stick)
	Sticks    []string `json:"sticks"`    // what is plugged in, for the explanation
	Installed bool     `json:"installed"` // Entware is set up on a stick already
}

var kNeeded = []struct{ id, name string }{
	{"opkg", "Поддержка открытых пакетов"},
	{"ext", "Файловая система Ext"},
	{"opkg-kmod-netfilter", "Модули ядра подсистемы Netfilter"},
}

// entwareURL: the official installers (bin.entware.net)
var entwareURL = map[string]string{
	"mipsel":  "https://bin.entware.net/mipselsf-k3.4/installer/mipsel-installer.tar.gz",
	"mips":    "https://bin.entware.net/mipssf-k3.4/installer/mips-installer.tar.gz",
	"aarch64": "https://bin.entware.net/aarch64-k3.10/installer/aarch64-installer.tar.gz",
}

// installerFor: Keenetic says "mips" both for little-endian MediaTek models (most: Extra, Air, City, Giga…)
// and for the big-endian DSL ones (EcoNet: DSL, Duo, Hero DSL…).
func installerFor(arch, model string) string {
	switch {
	case strings.Contains(arch, "aarch64") || strings.Contains(arch, "arm"):
		return "aarch64"
	case strings.Contains(strings.ToLower(model), "dsl") || strings.Contains(strings.ToLower(model), "duo"):
		return "mips"
	}
	return "mipsel"
}

func (a *App) KeeneticCheck(host, login, password string) KeeneticCheck {
	k, err := kLogin(strings.TrimSpace(host), strings.TrimSpace(login), password)
	if err != nil {
		return KeeneticCheck{Error: err.Error()}
	}
	var ver struct {
		Title       string `json:"title"`
		Arch        string `json:"arch"`
		Description string `json:"description"`
		Model       string `json:"model"`
		Components  string `json:"components"`
	}
	if err := k.get("show/version", &ver); err != nil {
		return KeeneticCheck{Error: "не удалось прочитать версию роутера: " + err.Error()}
	}
	r := KeeneticCheck{OK: true, Model: ver.Description, Firmware: ver.Title, Arch: ver.Arch}
	if r.Model == "" {
		r.Model = ver.Model
	}
	r.Installer = installerFor(ver.Arch, r.Model)
	have := map[string]bool{}
	for _, c := range strings.Split(strings.ReplaceAll(ver.Components, "\n", ""), ",") {
		have[strings.TrimSpace(c)] = true
	}
	for _, n := range kNeeded {
		if !have[n.id] {
			r.Missing = append(r.Missing, n.name)
		}
	}
	// the USB sticks: an ext4 partition with a label, mounted
	var media map[string]any
	if k.get("show/media", &media) == nil {
		for _, v := range media {
			m, _ := v.(map[string]any)
			parts := []any{}
			switch p := m["partition"].(type) {
			case []any:
				parts = p
			case map[string]any:
				parts = []any{p}
			}
			for _, pv := range parts {
				p, _ := pv.(map[string]any)
				label, _ := p["label"].(string)
				fs, _ := p["fstype"].(string)
				state, _ := p["state"].(string)
				r.Sticks = append(r.Sticks, fmt.Sprintf("%s (%s)", firstNonEmpty(label, "без метки"), fs))
				if fs == "ext4" && label != "" && state == "MOUNTED" && r.Label == "" {
					r.Label = label
				}
			}
		}
	}
	// Entware set up already: the running config has "opkg disk ..."
	if out, err := k.parse("show running-config"); err == nil && strings.Contains(out, "opkg disk") {
		r.Installed = true
	}
	return r
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// EntwareResult goes back to the window.
type EntwareResult struct {
	OK    bool   `json:"ok"`
	Error string `json:"error"`
	Port  int    `json:"port"` // where Entware's SSH answered
}

// entwareWait is how long to wait for Entware's SSH (replaced in tests)
var (
	entwareWait  = 10 * time.Minute
	entwarePorts = []int{22, 222}
)

// InstallEntware starts the installation on the stick LABEL, waits for Entware's SSH and sets the new root password.
func (a *App) InstallEntware(host, login, password, label, installer, newRoot string) EntwareResult {
	url := entwareURL[installer]
	if url == "" {
		return EntwareResult{Error: "неизвестный установщик"}
	}
	if len(newRoot) < 6 {
		return EntwareResult{Error: "Новый пароль root — хотя бы 6 знаков."}
	}
	if strings.ContainsAny(label, " :/\\\"'") || label == "" {
		return EntwareResult{Error: "Метка флешки — латиницей, без пробелов (например, ENTWARE). Переименуйте её при форматировании."}
	}
	k, err := kLogin(strings.TrimSpace(host), strings.TrimSpace(login), password)
	if err != nil {
		return EntwareResult{Error: err.Error()}
	}
	a.emit("sb:log", "opkg disk "+label+":/ "+url)
	if _, err := k.parse("opkg disk " + label + ":/ " + url); err != nil {
		return EntwareResult{Error: "роутер не принял команду установки: " + err.Error()}
	}
	k.parse("system configuration save")
	a.emit("sb:event", sbEvent{Kind: "entware", Fields: []string{"started"}})
	// Entware's own SSH comes up when the installation is done (port 22, or 222 when the router's SSH has 22)
	sshHost := strings.TrimSpace(host)
	if h, _, err := net.SplitHostPort(sshHost); err == nil {
		sshHost = h // "192.168.1.1:8080" (web interface on another port): SSH is on the same host
	}
	deadline := time.Now().Add(entwareWait)
	for time.Now().Before(deadline) {
		for _, p := range entwarePorts {
			c, err := ssh.Dial("tcp", net.JoinHostPort(sshHost, fmt.Sprint(p)), &ssh.ClientConfig{
				User: "root", Auth: []ssh.AuthMethod{ssh.Password("keenetic")},
				HostKeyCallback: ssh.InsecureIgnoreHostKey(), // a brand-new install: its key is remembered at the real connect
				Timeout:         5 * time.Second,
			})
			if err != nil {
				continue
			}
			err = setRootPassword(c, newRoot)
			c.Close()
			if err != nil {
				return EntwareResult{Error: "Entware установлен, но пароль сменить не удалось: " + err.Error() + ". Смените его вручную (PowerShell: ssh root@" + host + ", пароль keenetic, затем passwd)."}
			}
			a.emit("sb:event", sbEvent{Kind: "entware", Fields: []string{"done", fmt.Sprint(p)}})
			return EntwareResult{OK: true, Port: p}
		}
		a.emit("sb:event", sbEvent{Kind: "entware", Fields: []string{"waiting"}})
		time.Sleep(entwareStep)
	}
	return EntwareResult{Error: "Entware не поднялся за 10 минут. Посмотрите журнал роутера (Диагностика → Журнал): если там ошибка установки — возможно, нужен другой установщик."}
}

var entwareStep = 10 * time.Second

// setRootPassword runs passwd in a terminal and answers its two prompts.
func setRootPassword(c *ssh.Client, pw string) error {
	s, err := c.NewSession()
	if err != nil {
		return err
	}
	defer s.Close()
	if err := s.RequestPty("xterm", 24, 80, ssh.TerminalModes{ssh.ECHO: 0}); err != nil {
		return err
	}
	in, _ := s.StdinPipe()
	var out bytes.Buffer
	s.Stdout, s.Stderr = &out, &out
	if err := s.Start(passwdCmd); err != nil {
		return err
	}
	for i := 0; i < 2; i++ {
		time.Sleep(passwdPause)
		io.WriteString(in, pw+"\n")
	}
	done := make(chan error, 1)
	go func() { done <- s.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			return fmt.Errorf("passwd: %s", strings.TrimSpace(out.String()))
		}
		return nil
	case <-time.After(15 * time.Second):
		return fmt.Errorf("passwd не ответил")
	}
}

var (
	passwdPause = 700 * time.Millisecond
	passwdCmd   = "passwd" // replaced in tests
)
