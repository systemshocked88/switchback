package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestNewerVersion(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want bool
	}{
		{"0.7.1", "0.7.0", true},
		{"0.7.0", "0.7.0", false},
		{"0.7.0", "0.7.1", false},
		{"0.10.0", "0.9.3", true},
		{"1.0", "0.9.9", true},
		{"0.7", "0.7.0", false},
		{"0.7.1-beta", "0.7.0", false},
		{"", "0.7.0", false},
		{"abc", "0.7.0", false},
	} {
		if got := newerVersion(c.a, c.b); got != c.want {
			t.Errorf("newerVersion(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}

// A local server stands in for GitHub: nothing leaves the computer.
func TestCheckUpdate(t *testing.T) {
	tag := "v0.8.0"
	hits := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.URL.Path != "/someone/switchback/releases/latest" {
			http.NotFound(w, r)
			return
		}
		fmt.Fprintf(w, `{"tag_name":%q,"html_url":"https://evil.example/steal"}`, tag)
	}))
	defer srv.Close()
	old := updateAPI
	updateAPI = srv.URL + "/"
	defer func() { updateAPI = old }()

	if u := checkUpdate("", "", "0.7.1"); u != (UpdateInfo{}) || hits != 0 {
		t.Fatalf("no repository: nothing must be asked, got %+v after %d requests", u, hits)
	}
	u := checkUpdate("someone/switchback", "", "0.7.1")
	if !u.Newer || u.Latest != "0.8.0" {
		t.Fatalf("newer release not seen: %+v", u)
	}
	if u.URL != "https://github.com/someone/switchback/releases/latest" {
		t.Fatalf("the link must be built by the program, not taken from the answer: %q", u.URL)
	}
	if u := checkUpdate("someone/switchback", "", "0.8.0"); u.Newer {
		t.Fatalf("same version shown as newer: %+v", u)
	}
	tag = "<script>"
	if u := checkUpdate("someone/switchback", "", "0.7.1"); u != (UpdateInfo{}) {
		t.Fatalf("a strange tag must be ignored: %+v", u)
	}
	if u := checkUpdate("someone/missing", "", "0.7.1"); u != (UpdateInfo{}) {
		t.Fatalf("an error answer must be ignored: %+v", u)
	}
}

// GitHub answers with an error: the program asks the mirror (a second local server) for its tags and
// links to the mirror's page. Both servers are local: nothing leaves the computer.
func TestCheckUpdateMirror(t *testing.T) {
	gh := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "gone", http.StatusNotFound)
	}))
	defer gh.Close()
	tags := `[{"name":"v0.7.4"},{"name":"v0.10.0"},{"name":"v0.9.1"},{"name":"<b>x</b>"}]`
	asked := ""
	cb := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		asked = r.URL.Path
		if r.URL.Path != "/mirror/switchback/tags" {
			http.NotFound(w, r)
			return
		}
		fmt.Fprint(w, tags)
	}))
	defer cb.Close()
	oldU, oldM := updateAPI, mirrorAPI
	updateAPI, mirrorAPI = gh.URL+"/", cb.URL+"/"
	defer func() { updateAPI, mirrorAPI = oldU, oldM }()

	u := checkUpdate("someone/switchback", "mirror/switchback", "0.7.5")
	if asked != "/mirror/switchback/tags" {
		t.Fatalf("the mirror was not asked for its tags: %q", asked)
	}
	if !u.Newer || !u.Mirror || u.Latest != "0.10.0" {
		t.Fatalf("the newest tag of the mirror not seen: %+v", u)
	}
	if u.URL != mirrorSite+"mirror/switchback/tags" {
		t.Fatalf("the link must be the mirror's page built by the program: %q", u.URL)
	}
	asked = ""
	if u := checkUpdate("someone/switchback", "", "0.7.5"); u != (UpdateInfo{}) || asked != "" {
		t.Fatalf("no mirror set: nothing must be asked, got %+v", u)
	}
	if u := checkUpdate("someone/switchback", "mirror/missing", "0.7.5"); u != (UpdateInfo{}) {
		t.Fatalf("both down: nothing to say, got %+v", u)
	}
	tags = `[{"name":"latest"}]`
	if u := checkUpdate("someone/switchback", "mirror/switchback", "0.7.5"); u != (UpdateInfo{}) {
		t.Fatalf("no version tags on the mirror: nothing to say, got %+v", u)
	}
}
