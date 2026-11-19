// lists-sign makes a release of the lists: lists/SHA256SUMS (sha256 of VERSION and of every list) and
// lists/SHA256SUMS.sig (Ed25519 signature of SHA256SUMS, base64), which the program checks before it
// sends lists to a router (app/lists.go). The private key lives in a file OUTSIDE the repository.
//
//	go run ./tools/lists-sign -genkey C:\keys\switchback-lists.key   (once: prints the public key for app/lists.go)
//	go run ./tools/lists-sign -key C:\keys\switchback-lists.key -dir ../lists
//	go run ./tools/lists-sign -sums-only -dir ../lists                (SHA256SUMS only, no signature)
//
// Raise lists/VERSION before signing: the program takes only a version newer than the router's.
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func main() {
	genkey := flag.String("genkey", "", "make a new key pair: the private key goes into this file (outside the repository)")
	key := flag.String("key", "", "file with the private key")
	dir := flag.String("dir", "../lists", "the lists folder")
	sumsOnly := flag.Bool("sums-only", false, "write SHA256SUMS only")
	flag.Parse()
	var err error
	switch {
	case *genkey != "":
		var pub string
		if pub, err = genKey(*genkey); err == nil {
			fmt.Println("Открытый ключ (вставить в listsPubKey в app/lists.go):")
			fmt.Println(pub)
		}
	case *sumsOnly:
		_, err = writeSums(*dir)
	case *key != "":
		err = sign(*key, *dir)
		if err == nil {
			fmt.Println("Готово:", filepath.Join(*dir, "SHA256SUMS"), "и SHA256SUMS.sig")
		}
	default:
		flag.Usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "Ошибка:", err)
		os.Exit(1)
	}
}

// inRepo: is path inside a git working copy (a folder with .git above it)?
func inRepo(path string) bool {
	d, err := filepath.Abs(filepath.Dir(path))
	if err != nil {
		return true
	}
	for {
		if _, err := os.Stat(filepath.Join(d, ".git")); err == nil {
			return true
		}
		up := filepath.Dir(d)
		if up == d {
			return false
		}
		d = up
	}
}

func genKey(path string) (string, error) {
	if inRepo(path) {
		return "", errors.New("закрытый ключ нельзя класть в папку с репозиторием")
	}
	if _, err := os.Stat(path); err == nil {
		return "", errors.New("файл уже есть: " + path)
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(path, []byte(base64.StdEncoding.EncodeToString(priv.Seed())+"\n"), 0600); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(pub), nil
}

func readKey(path string) (ed25519.PrivateKey, error) {
	if inRepo(path) {
		return nil, errors.New("закрытый ключ лежит в папке с репозиторием — уберите его оттуда")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(b)))
	if err != nil || len(seed) != ed25519.SeedSize {
		return nil, errors.New("непонятный файл ключа")
	}
	return ed25519.NewKeyFromSeed(seed), nil
}

// writeSums: sha256 of every file in dir except SHA256SUMS*, sorted by name, in sha256sum's format
func writeSums(dir string) ([]byte, error) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range ents {
		if e.Type().IsRegular() && !strings.HasPrefix(e.Name(), "SHA256SUMS") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	var sb strings.Builder
	for _, n := range names {
		b, err := os.ReadFile(filepath.Join(dir, n))
		if err != nil {
			return nil, err
		}
		if strings.Contains(string(b), "\r") {
			return nil, errors.New(n + ": строки с концами Windows (CR), роутер их так не прочтёт")
		}
		h := sha256.Sum256(b)
		fmt.Fprintf(&sb, "%s  %s\n", hex.EncodeToString(h[:]), n)
	}
	sums := []byte(sb.String())
	return sums, os.WriteFile(filepath.Join(dir, "SHA256SUMS"), sums, 0644)
}

func sign(keyPath, dir string) error {
	priv, err := readKey(keyPath)
	if err != nil {
		return err
	}
	sums, err := writeSums(dir)
	if err != nil {
		return err
	}
	sig := base64.StdEncoding.EncodeToString(ed25519.Sign(priv, sums)) + "\n"
	return os.WriteFile(filepath.Join(dir, "SHA256SUMS.sig"), []byte(sig), 0644)
}
