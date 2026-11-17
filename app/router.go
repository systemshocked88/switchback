package main

// Talking to the router over SSH: connect, remember its key, upload the installer, run it.

import (
	"bufio"
	"bytes"
	_ "embed"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

//go:generate go run ./tools/bundle

// The installer, packed by tools/bundle before every build.
//
//go:embed installer/switchback.tar.gz
var installerTar []byte

// Where the installer is unpacked on the router (RAM disk: gone after a reboot).
const defaultRemoteDir = "/tmp/switchback"

var errHostKeyChanged = errors.New("host key changed")

// ---------- known router keys (first connection: remember; later: must match) ----------

type knownHosts struct {
	path string
	mu   sync.Mutex
}

func defaultKnownHosts() *knownHosts {
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = os.TempDir()
	}
	return &knownHosts{path: filepath.Join(dir, "switchback", "known_hosts")}
}

func (k *knownHosts) lookup(addr string) (string, bool) {
	data, err := os.ReadFile(k.path)
	if err != nil {
		return "", false
	}
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) == 2 && f[0] == addr {
			return f[1], true
		}
	}
	return "", false
}

func (k *knownHosts) remember(addr, fp string) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	var keep []string
	if data, err := os.ReadFile(k.path); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			if f := strings.Fields(line); len(f) == 2 && f[0] != addr {
				keep = append(keep, line)
			}
		}
	}
	keep = append(keep, addr+" "+fp)
	os.MkdirAll(filepath.Dir(k.path), 0o700)
	return os.WriteFile(k.path, []byte(strings.Join(keep, "\n")+"\n"), 0o600)
}

func (k *knownHosts) forget(addr string) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	data, err := os.ReadFile(k.path)
	if err != nil {
		return nil
	}
	var keep []string
	for _, line := range strings.Split(string(data), "\n") {
		if f := strings.Fields(line); len(f) == 2 && f[0] != addr {
			keep = append(keep, line)
		}
	}
	return os.WriteFile(k.path, []byte(strings.Join(keep, "\n")+"\n"), 0o600)
}

// ---------- connection ----------

type connectInfo struct {
	Fingerprint string `json:"fingerprint"` // SHA256:... of the router's key
	NewKey      bool   `json:"newKey"`      // first connection to this address
}

func dialRouter(host string, port int, user, password string, kh *knownHosts) (*ssh.Client, connectInfo, error) {
	addr := net.JoinHostPort(host, strconv.Itoa(port))
	var info connectInfo
	cfg := &ssh.ClientConfig{
		User: user,
		Auth: []ssh.AuthMethod{
			ssh.Password(password),
			// dropbear on some firmwares asks for the password this way
			ssh.KeyboardInteractive(func(_, _ string, qs []string, _ []bool) ([]string, error) {
				a := make([]string, len(qs))
				for i := range a {
					a[i] = password
				}
				return a, nil
			}),
		},
		HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
			fp := ssh.FingerprintSHA256(key)
			info.Fingerprint = fp
			old, ok := kh.lookup(addr)
			if !ok {
				info.NewKey = true
				return nil // remembered only after a successful login
			}
			if old != fp {
				return errHostKeyChanged
			}
			return nil
		},
		Timeout: 10 * time.Second,
	}
	c, err := ssh.Dial("tcp", addr, cfg)
	if err != nil {
		return nil, info, err
	}
	if info.NewKey {
		kh.remember(addr, info.Fingerprint)
	}
	return c, info, nil
}

// friendlyError turns SSH errors into a sentence for the window.
func friendlyError(err error, host string, port int) string {
	s := err.Error()
	switch {
	case errors.Is(err, errHostKeyChanged):
		return "Ключ роутера изменился с прошлого раза. Так бывает после сброса или перепрошивки — " +
			"или если кто-то подменяет роутер в сети. Если вы сбрасывали роутер, нажмите «Забыть ключ» и подключитесь снова."
	case strings.Contains(s, "unable to authenticate"):
		return "Роутер не принял пользователя или пароль."
	case strings.Contains(s, "connection refused") || strings.Contains(s, "actively refused"):
		return fmt.Sprintf("Роутер %s не принимает SSH на порту %d. На Keenetic SSH даёт Entware (обычно порт 22 или 222).", host, port)
	case strings.Contains(s, "timeout") || strings.Contains(s, "timed out") || strings.Contains(s, "no route"):
		return fmt.Sprintf("Роутер %s не отвечает. Проверьте адрес и что компьютер подключён к этой сети.", host)
	}
	return "Не удалось подключиться: " + s
}

// ---------- running commands ----------

// runStream runs cmd on the router, feeding stdin, and calls onLine for every output line.
// Returns the command's exit code.
func runStream(c *ssh.Client, cmd string, stdin io.Reader, onLine func(string)) (int, error) {
	s, err := c.NewSession()
	if err != nil {
		return -1, err
	}
	defer s.Close()
	if stdin != nil {
		s.Stdin = stdin
	}
	out, _ := s.StdoutPipe()
	errOut, _ := s.StderrPipe()
	if err := s.Start(cmd); err != nil {
		return -1, err
	}
	var mu sync.Mutex
	var wg sync.WaitGroup
	read := func(r io.Reader) {
		defer wg.Done()
		sc := bufio.NewScanner(r)
		sc.Buffer(make([]byte, 64*1024), 1024*1024)
		for sc.Scan() {
			mu.Lock()
			onLine(strings.TrimRight(sc.Text(), "\r"))
			mu.Unlock()
		}
	}
	wg.Add(2)
	go read(out)
	go read(errOut)
	wg.Wait()
	err = s.Wait()
	var ee *ssh.ExitError
	if errors.As(err, &ee) {
		return ee.ExitStatus(), nil
	}
	if err != nil {
		return -1, err
	}
	return 0, nil
}

func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// uploadInstaller unpacks the embedded installer into dir on the router.
func uploadInstaller(c *ssh.Client, dir string, onLine func(string)) error {
	q := shellQuote(dir)
	code, err := runStream(c, "rm -rf "+q+" && mkdir -p "+q+" && tar xzf - -C "+q+" && test -f "+q+"/install.sh",
		bytes.NewReader(installerTar), onLine)
	if err != nil {
		return err
	}
	if code != 0 {
		return fmt.Errorf("не удалось распаковать установщик на роутере (код %d)", code)
	}
	return nil
}

// ---------- installer output ----------

// sbEvent is one "@@sb" line of install.sh --progress (format: docs/answers.md).
type sbEvent struct {
	Kind   string   `json:"kind"`
	Fields []string `json:"fields"`
}

func parseEvent(line string) (sbEvent, bool) {
	if !strings.HasPrefix(line, "@@sb\t") {
		return sbEvent{}, false
	}
	p := strings.Split(line, "\t")
	if len(p) < 2 {
		return sbEvent{}, false
	}
	return sbEvent{Kind: p[1], Fields: p[2:]}, true
}
