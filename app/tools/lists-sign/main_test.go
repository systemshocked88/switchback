package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A throwaway key in a temporary folder (outside the repository): sign, then check as the program does.
func TestSign(t *testing.T) {
	keys, lists := t.TempDir(), t.TempDir()
	os.WriteFile(filepath.Join(lists, "VERSION"), []byte("3\n"), 0644)
	os.WriteFile(filepath.Join(lists, "telegram.nets"), []byte("91.108.4.0/22\n"), 0644)
	kf := filepath.Join(keys, "test.key")
	pubB64, err := genKey(kf)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := genKey(kf); err == nil {
		t.Fatal("an existing key file must not be overwritten")
	}
	if err := sign(kf, lists); err != nil {
		t.Fatal(err)
	}
	sums, _ := os.ReadFile(filepath.Join(lists, "SHA256SUMS"))
	sig, _ := os.ReadFile(filepath.Join(lists, "SHA256SUMS.sig"))
	if !strings.Contains(string(sums), "  VERSION\n") || !strings.Contains(string(sums), "  telegram.nets\n") ||
		strings.Contains(string(sums), "SHA256SUMS") {
		t.Fatalf("sums: %q", sums)
	}
	pub, _ := base64.StdEncoding.DecodeString(pubB64)
	raw, _ := base64.StdEncoding.DecodeString(strings.TrimSpace(string(sig)))
	if !ed25519.Verify(pub, sums, raw) {
		t.Fatal("signature does not check")
	}
	os.WriteFile(filepath.Join(lists, "bad.domains"), []byte("a.com\r\n"), 0644)
	if err := sign(kf, lists); err == nil {
		t.Fatal("CRLF lines must be refused")
	}
}

func TestKeyNotInRepo(t *testing.T) {
	// this test runs inside the repository: a key here is refused
	if _, err := genKey("in-repo-test.key"); err == nil {
		os.Remove("in-repo-test.key")
		t.Fatal("a private key inside the repository must be refused")
	}
}
