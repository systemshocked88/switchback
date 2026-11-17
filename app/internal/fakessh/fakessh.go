// Package fakessh is a tiny SSH server for tests and development: it accepts one password
// and runs every command with a local POSIX shell (Git Bash on Windows), so the program can be
// tried against tests/fake-keenetic.sh without a real router. Never used by switchback.exe.
package fakessh

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"golang.org/x/crypto/ssh"
)

// FindSh returns a POSIX sh, or "" if there is none.
func FindSh() string {
	if p, err := exec.LookPath("sh"); err == nil {
		return p
	}
	for _, p := range []string{`C:\Program Files\Git\usr\bin\sh.exe`, `C:\Program Files\Git\bin\sh.exe`} {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

// PosixPath turns C:\x\y into /c/x/y for Git Bash.
func PosixPath(p string) string {
	if runtime.GOOS != "windows" {
		return p
	}
	p = filepath.ToSlash(p)
	if len(p) > 1 && p[1] == ':' {
		p = "/" + strings.ToLower(p[:1]) + p[2:]
	}
	return p
}

// ShEnv is the environment for running sh: rm, tar, sed... live next to it on Windows.
func ShEnv(sh string, extra ...string) []string {
	env := append(os.Environ(), extra...)
	return append(env, "PATH="+filepath.Dir(sh)+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// splitPath takes a PATH= entry out of env. ShEnv's own PATH (Git Bash first) would win over it
// on Windows, and then a real program (passwd!) runs instead of a test's fake one. So the
// caller puts these folders first inside the shell itself.
func splitPath(env []string) (rest []string, first string) {
	for _, e := range env {
		if strings.HasPrefix(strings.ToUpper(e), "PATH=") {
			first = e[5:]
			continue
		}
		rest = append(rest, e)
	}
	return rest, first
}

// MakeFakeKeenetic builds the fake Keenetic /opt in dir with tests/fake-keenetic.sh from repo.
func MakeFakeKeenetic(sh, repo, dir string) error {
	os.MkdirAll(dir, 0o755)
	cmd := exec.Command(sh, PosixPath(filepath.Join(repo, "tests", "fake-keenetic.sh")), PosixPath(dir))
	cmd.Env = ShEnv(sh)
	if out, err := cmd.CombinedOutput(); err != nil {
		return errors.New(err.Error() + ": " + string(out))
	}
	return nil
}

// NewKey makes a random host key.
func NewKey() ssh.Signer {
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(priv)
	return s
}

// Serve accepts connections on ln until it is closed. Password: password.
// Commands run as `sh -c CMD` with env added.
func Serve(ln net.Listener, key ssh.Signer, password, sh string, env []string) {
	cfg := &ssh.ServerConfig{
		PasswordCallback: func(_ ssh.ConnMetadata, pw []byte) (*ssh.Permissions, error) {
			if string(pw) == password {
				return nil, nil
			}
			return nil, errors.New("wrong password")
		},
	}
	cfg.AddHostKey(key)
	for {
		nc, err := ln.Accept()
		if err != nil {
			return
		}
		go serveConn(nc, cfg, sh, env)
	}
}

func serveConn(nc net.Conn, cfg *ssh.ServerConfig, sh string, env []string) {
	_, chans, reqs, err := ssh.NewServerConn(nc, cfg)
	if err != nil {
		return
	}
	go ssh.DiscardRequests(reqs)
	for nch := range chans {
		ch, creqs, err := nch.Accept()
		if err != nil {
			continue
		}
		go func() {
			for r := range creqs {
				if r.Type == "pty-req" { // a terminal is asked for (passwd): fine, plain pipes are enough here
					r.Reply(true, nil)
					continue
				}
				if r.Type != "exec" || len(r.Payload) < 4 {
					r.Reply(false, nil)
					continue
				}
				n := binary.BigEndian.Uint32(r.Payload[:4])
				cmdline := string(r.Payload[4 : 4+n])
				r.Reply(true, nil)
				rest, first := splitPath(env)
				if first != "" {
					cmdline = "PATH='" + first + "':\"$PATH\"; export PATH; " + cmdline
				}
				cmd := exec.Command(sh, "-c", cmdline)
				cmd.Env = ShEnv(sh, rest...)
				stdin, _ := cmd.StdinPipe()
				cmd.Stdout, cmd.Stderr = ch, ch.Stderr()
				cmd.Start()
				go func() { io.Copy(stdin, ch); stdin.Close() }()
				code := 0
				if err := cmd.Wait(); err != nil {
					var ee *exec.ExitError
					if errors.As(err, &ee) {
						code = ee.ExitCode()
					} else {
						code = 255
					}
				}
				st := make([]byte, 4)
				binary.BigEndian.PutUint32(st, uint32(code))
				ch.SendRequest("exit-status", false, st)
				ch.Close()
				return
			}
		}()
	}
}
