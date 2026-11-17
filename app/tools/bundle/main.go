// bundle packs the router installer (install.sh, lib/, platforms/) into
// app/installer/switchback.tar.gz, which is embedded into switchback.exe.
// Runs before every build (wails.json preBuildHooks) and via `go generate`.
package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"
)

func main() {
	app, err := findAppDir()
	if err != nil {
		fail(err)
	}
	repo := filepath.Dir(app)

	var files []string
	for _, pattern := range []string{"install.sh", "uninstall.sh", "lib/*.sh", "platforms/*.sh"} {
		m, _ := filepath.Glob(filepath.Join(repo, filepath.FromSlash(pattern)))
		files = append(files, m...)
	}
	if len(files) < 3 {
		fail(fmt.Errorf("installer files not found next to %s", app))
	}
	sort.Strings(files)

	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	stamp := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC) // fixed: same input -> same archive
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			fail(err)
		}
		// the router's sh fails on Windows line endings
		data = bytes.ReplaceAll(data, []byte("\r\n"), []byte("\n"))
		rel, _ := filepath.Rel(repo, f)
		mode := int64(0o644)
		if filepath.Dir(rel) == "." {
			mode = 0o755
		}
		hdr := &tar.Header{Name: filepath.ToSlash(rel), Mode: mode, Size: int64(len(data)), ModTime: stamp, Typeflag: tar.TypeReg}
		if err := tw.WriteHeader(hdr); err != nil {
			fail(err)
		}
		tw.Write(data)
	}
	tw.Close()
	gz.Close()

	out := filepath.Join(app, "installer", "switchback.tar.gz")
	os.MkdirAll(filepath.Dir(out), 0o755)
	if err := os.WriteFile(out, buf.Bytes(), 0o644); err != nil {
		fail(err)
	}
	fmt.Printf("bundle: %d files -> %s (%d bytes)\n", len(files), out, buf.Len())
}

// findAppDir walks up from the current folder to the one holding wails.json.
func findAppDir() (string, error) {
	d, _ := os.Getwd()
	for {
		if _, err := os.Stat(filepath.Join(d, "wails.json")); err == nil {
			return d, nil
		}
		p := filepath.Dir(d)
		if p == d {
			return "", fmt.Errorf("wails.json not found above the current folder")
		}
		d = p
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "bundle:", err)
	os.Exit(1)
}
