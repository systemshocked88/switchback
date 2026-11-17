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
// shows a line with a link to the releases page. Nothing is downloaded or installed.
//
// updateRepo is "owner/name" on GitHub. Empty: no request is made.
const updateRepo = "systemshocked88/switchback"

// tests point it at a local server
var updateAPI = "https://api.github.com/repos/"

type UpdateInfo struct {
	Latest string `json:"latest"` // version of the latest release, "" if unknown
	URL    string `json:"url"`    // the releases page
	Newer  bool   `json:"newer"`  // the latest release is newer than this program
}

// CheckUpdate never fails loudly: no network or a strange answer mean "nothing to say".
func (a *App) CheckUpdate() UpdateInfo { return checkUpdate(updateRepo, appVersion) }

func checkUpdate(repo, current string) UpdateInfo {
	if repo == "" {
		return UpdateInfo{}
	}
	req, err := http.NewRequest("GET", updateAPI+repo+"/releases/latest", nil)
	if err != nil {
		return UpdateInfo{}
	}
	req.Header.Set("User-Agent", "switchback")
	req.Header.Set("Accept", "application/vnd.github+json")
	r, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		return UpdateInfo{}
	}
	defer r.Body.Close()
	if r.StatusCode != 200 {
		return UpdateInfo{}
	}
	var rel struct {
		Tag string `json:"tag_name"`
	}
	if json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&rel) != nil {
		return UpdateInfo{}
	}
	latest := strings.TrimPrefix(strings.TrimSpace(rel.Tag), "v")
	if _, ok := versionParts(latest); !ok {
		return UpdateInfo{}
	}
	// the link is built here, never taken from the answer
	return UpdateInfo{Latest: latest, URL: "https://github.com/" + repo + "/releases/latest", Newer: newerVersion(latest, current)}
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
