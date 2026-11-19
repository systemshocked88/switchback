package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

// TestRepoListsSigned: the lists in the repository are signed with the key the program trusts, and every
// sum matches - otherwise «Обновить списки» would refuse the published lists. After any change in lists/
// run: go run ./tools/lists-sign -key <private key outside the repository>
func TestRepoListsSigned(t *testing.T) {
	dir := filepath.Join("..", "lists")
	sums, err := os.ReadFile(filepath.Join(dir, "SHA256SUMS"))
	if err != nil {
		t.Skip("lists/SHA256SUMS not there yet")
	}
	sig, err := os.ReadFile(filepath.Join(dir, "SHA256SUMS.sig"))
	if err != nil {
		t.Fatalf("SHA256SUMS without SHA256SUMS.sig: %v", err)
	}
	pub, err := base64.StdEncoding.DecodeString(listsPubKey)
	if err != nil {
		t.Fatalf("listsPubKey: %v", err)
	}
	if err := checkSig(ed25519.PublicKey(pub), sums, sig); err != nil {
		t.Fatalf("lists/ are not signed with listsPubKey (re-sign them): %v", err)
	}
	m, err := parseSums(sums)
	if err != nil {
		t.Fatal(err)
	}
	for name, want := range m {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		h := sha256.Sum256(b)
		if hex.EncodeToString(h[:]) != want {
			t.Errorf("%s changed after signing: re-sign lists/", name)
		}
	}
}
