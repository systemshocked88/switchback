// fakerouter: a fake Keenetic reachable over SSH, for trying switchback.exe without a router.
//
//	go run ./tools/fakerouter            -> 127.0.0.1:2222, user root, password "secret"
//
// The fake /opt is built from tests/fake-keenetic.sh in a temp folder; nothing real is touched.
package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"

	"switchback/internal/fakessh"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:2222", "listen address")
	flag.Parse()

	sh := fakessh.FindSh()
	if sh == "" {
		fmt.Fprintln(os.Stderr, "no POSIX sh (install Git for Windows)")
		os.Exit(1)
	}
	wd, _ := os.Getwd()
	repo := wd
	for ; ; repo = filepath.Dir(repo) {
		if _, err := os.Stat(filepath.Join(repo, "tests", "fake-keenetic.sh")); err == nil {
			break
		}
		if filepath.Dir(repo) == repo {
			fmt.Fprintln(os.Stderr, "run inside the switchback folder")
			os.Exit(1)
		}
	}
	dir, _ := os.MkdirTemp("", "fakerouter-")
	opt := filepath.Join(dir, "opt")
	if err := fakessh.MakeFakeKeenetic(sh, repo, opt); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("fake Keenetic on %s (root / secret), files in %s\n", *addr, opt)
	fakessh.Serve(ln, fakessh.NewKey(), "secret", sh,
		[]string{"SB_OPT=" + fakessh.PosixPath(opt), "SB_TEST=1", "SB_PLATFORM=keenetic"})
}
