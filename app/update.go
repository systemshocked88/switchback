package main

import (
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Is there a newer switchback? The program asks GitHub for the latest release of updateRepo and
// shows a line with a link to the releases page (or, if GitHub does not answer, to the mirror).
// Nothing is downloaded or installed.
//
// updateRepo is "owner/name" on GitHub. Empty: no request is made.
const updateRepo = "systemshocked88/switchback"

// The spare copy on Codeberg (the public branch and the version tags are sent there with each release):
// asked only when GitHub does not answer (no network to it, an error, the repository gone). There are
// no release files there, so the program only opens its page in the browser. Empty: no spare copy.
const mirrorRepo = "systemshocked/switchback"
const mirrorSite = "https://codeberg.org/"

// tests point them at a local server
var updateAPI = "https://api.github.com/repos/"
var mirrorAPI = mirrorSite + "api/v1/repos/"

type UpdateInfo struct {
	Latest string `json:"latest"` // version of the latest release, "" if unknown
	URL    string `json:"url"`    // the releases page
	Newer  bool   `json:"newer"`  // the latest release is newer than this program
	Mirror bool   `json:"mirror"` // GitHub did not answer; URL is the page of the mirror
}

// CheckUpdate never fails loudly: no network or a strange answer mean "nothing to say".
func (a *App) CheckUpdate() UpdateInfo { return checkUpdate(updateRepo, mirrorRepo, appVersion) }

func checkUpdate(repo, mirror, current string) UpdateInfo {
	if repo == "" {
		return UpdateInfo{}
	}
	body, ok := getJSON(updateAPI + repo + "/releases/latest")
	if !ok {
		return checkMirror(mirror, current)
	}
	var rel struct {
		Tag string `json:"tag_name"`
	}
	if json.Unmarshal(body, &rel) != nil {
		return UpdateInfo{}
	}
	latest := strings.TrimPrefix(strings.TrimSpace(rel.Tag), "v")
	if _, ok := versionParts(latest); !ok {
		return UpdateInfo{}
	}
	// the link is built here, never taken from the answer
	return UpdateInfo{Latest: latest, URL: "https://github.com/" + repo + "/releases/latest", Newer: newerVersion(latest, current)}
}

// checkMirror: the newest version tag of the mirror (Forgejo API, /tags: the copy has the tags,
// releases may be missing there). The link is the mirror's tags page, built here.
func checkMirror(mirror, current string) UpdateInfo {
	if mirror == "" {
		return UpdateInfo{}
	}
	body, ok := getJSON(mirrorAPI + mirror + "/tags?limit=50")
	if !ok {
		return UpdateInfo{}
	}
	var tags []struct {
		Name string `json:"name"`
	}
	if json.Unmarshal(body, &tags) != nil {
		return UpdateInfo{}
	}
	latest := ""
	for _, t := range tags {
		v := strings.TrimPrefix(strings.TrimSpace(t.Name), "v")
		if _, ok := versionParts(v); ok && (latest == "" || newerVersion(v, latest)) {
			latest = v
		}
	}
	if latest == "" {
		return UpdateInfo{}
	}
	return UpdateInfo{Latest: latest, URL: mirrorSite + mirror + "/tags", Newer: newerVersion(latest, current), Mirror: true}
}

// getJSON: the body of a 200 answer (at most 1 MB) within 10 seconds; anything else is false.
func getJSON(url string) ([]byte, bool) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, false
	}
	req.Header.Set("User-Agent", "switchback")
	req.Header.Set("Accept", "application/json")
	r, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		return nil, false
	}
	defer r.Body.Close()
	if r.StatusCode != 200 {
		return nil, false
	}
	b, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	return b, err == nil
}

// versionParts: "0.7.1" -> [0 7 1]; anything but dotted numbers is refused.
func versionParts(v string) ([]int, bool) {
	if v == "" || len(v) > 20 {
		return nil, false
	}
	var out []int
	for _, p := range strings.Split(v, ".") {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 {
			return nil, false
		}
		out = append(out, n)
	}
	return out, true
}

// newerVersion reports whether a is newer than b ("0.10.0" is newer than "0.9.3").
func newerVersion(a, b string) bool {
	pa, ok1 := versionParts(a)
	pb, ok2 := versionParts(b)
	if !ok1 || !ok2 {
		return false
	}
	for i := 0; i < len(pa) || i < len(pb); i++ {
		x, y := 0, 0
		if i < len(pa) {
			x = pa[i]
		}
		if i < len(pb) {
			y = pb[i]
		}
		if x != y {
			return x > y
		}
	}
	return false
}
