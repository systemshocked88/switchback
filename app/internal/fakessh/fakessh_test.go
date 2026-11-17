package fakessh

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
)

// A test's fake program must win over a real one with the same name (9 Nov: the real passwd ran).
// Checked with the harmless ls: at worst the real one lists a folder.
func TestFakeProgramsComeFirst(t *testing.T) {
	sh := FindSh()
	if sh == "" {
		t.Skip("no sh")
	}
	bin := t.TempDir()
	os.WriteFile(filepath.Join(bin, "ls"), []byte("#!/bin/sh\necho FAKE\n"), 0o755)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go Serve(ln, NewKey(), "pw", sh, []string{"PATH=" + PosixPath(bin) + ":/usr/bin:/bin"})
	c, err := ssh.Dial("tcp", ln.Addr().String(), &ssh.ClientConfig{
		User: "root", Auth: []ssh.AuthMethod{ssh.Password("pw")}, HostKeyCallback: ssh.InsecureIgnoreHostKey(),
	})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	s, _ := c.NewSession()
	out, _ := s.CombinedOutput("ls")
	if strings.TrimSpace(string(out)) != "FAKE" {
		t.Fatalf("the real ls ran instead of the fake one: %q", out)
	}
}
