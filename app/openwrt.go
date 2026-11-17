package main

// "Will my router work?": the model is looked up in the official OpenWrt release data, and a
// downloaded firmware file is checked against the official checksums. The program never flashes.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

var openwrtBase = "https://downloads.openwrt.org" // replaced in tests

type owTitle struct {
	Vendor  string `json:"vendor"`
	Model   string `json:"model"`
	Variant string `json:"variant"`
	Title   string `json:"title"`
}

func (t owTitle) String() string {
	if t.Title != "" {
		return t.Title
	}
	return strings.TrimSpace(strings.Join([]string{t.Vendor, t.Model, t.Variant}, " "))
}

type owProfile struct {
	ID     string    `json:"id"`
	Target string    `json:"target"`
	Titles []owTitle `json:"titles"`
}

var owCache struct {
	sync.Mutex
	version  string
	profiles []owProfile
}

func owGet(path string, v any) error {
	cl := &http.Client{Timeout: 30 * time.Second}
	r, err := cl.Get(openwrtBase + path)
	if err != nil {
		return err
	}
	defer r.Body.Close()
	if r.StatusCode != 200 {
		return fmt.Errorf("сервер OpenWrt ответил %d", r.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(r.Body, 32<<20)).Decode(v)
}

// owLoad fetches the stable version and its device list once per run.
func owLoad() (string, []owProfile, error) {
	owCache.Lock()
	defer owCache.Unlock()
	if owCache.version != "" {
		return owCache.version, owCache.profiles, nil
	}
	var vers struct {
		Stable string `json:"stable_version"`
	}
	if err := owGet("/.versions.json", &vers); err != nil || vers.Stable == "" {
		return "", nil, fmt.Errorf("не удалось получить данные с downloads.openwrt.org: %v", err)
	}
	var ov struct {
		Profiles []owProfile `json:"profiles"`
	}
	if err := owGet("/releases/"+vers.Stable+"/.overview.json", &ov); err != nil {
		return "", nil, fmt.Errorf("не удалось получить список устройств OpenWrt: %v", err)
	}
	owCache.version, owCache.profiles = vers.Stable, ov.Profiles
	return owCache.version, owCache.profiles, nil
}

func norm(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// DeviceMatch is one OpenWrt device that fits the query.
type DeviceMatch struct {
	ID          string `json:"id"`
	Target      string `json:"target"`
	Title       string `json:"title"`
	SelectorURL string `json:"selectorUrl"` // official firmware selector for this exact device
	InfoURL     string `json:"infoUrl"`     // search on openwrt.org: device page with install steps
}

type ModelCheck struct {
	Version string        `json:"version"`
	Matches []DeviceMatch `json:"matches"`
	More    bool          `json:"more"`
	Error   string        `json:"error"`
}

// CheckModel looks the model up in the latest stable OpenWrt release.
func (a *App) CheckModel(query string) ModelCheck {
	var toks []string
	for _, f := range strings.Fields(query) {
		if n := norm(f); n != "" {
			toks = append(toks, n)
		}
	}
	if len(toks) == 0 || len(strings.Join(toks, "")) < 3 {
		return ModelCheck{Error: "Введите модель с наклейки роутера, например «Archer C6 v3» или «AX3000T»."}
	}
	ver, profs, err := owLoad()
	if err != nil {
		return ModelCheck{Error: err.Error()}
	}
	// a device matches if every query word is inside its name; if some devices have every query word
	// as a whole word ("c6" = "C6", not "C60"), only those are shown
	exactOnly := false
	type hit struct {
		p     owProfile
		t     owTitle
		exact bool
	}
	var hits []hit
	for _, p := range profs {
		for _, t := range p.Titles {
			full := t.Vendor + " " + t.Model + " " + t.Variant + " " + t.Title
			hay := norm(full)
			words := map[string]bool{}
			for _, w := range strings.FieldsFunc(full, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) }) {
				words[norm(w)] = true
			}
			all, exact := true, true
			for _, k := range toks {
				if !strings.Contains(hay, k) {
					all = false
					break
				}
				if !words[k] {
					exact = false
				}
			}
			if all {
				hits = append(hits, hit{p, t, exact})
				exactOnly = exactOnly || exact
				break // one line per device
			}
		}
	}
	res := ModelCheck{Version: ver}
	for _, h := range hits {
		if exactOnly && !h.exact {
			continue
		}
		p, t := h.p, h.t
		if len(res.Matches) >= 30 {
			res.More = true
			break
		}
		res.Matches = append(res.Matches, DeviceMatch{
			ID: p.ID, Target: p.Target, Title: t.String(),
			SelectorURL: "https://firmware-selector.openwrt.org/?version=" + url.QueryEscape(ver) +
				"&target=" + url.QueryEscape(p.Target) + "&id=" + url.QueryEscape(p.ID),
			InfoURL: "https://openwrt.org/start?do=search&q=" + url.QueryEscape(strings.TrimSpace(t.Vendor+" "+t.Model)),
		})
	}
	return res
}

// ImageCheck: is the downloaded file an official OpenWrt image for this device, and of which kind.
type ImageCheck struct {
	OK         bool     `json:"ok"`     // file matches an official image of this device
	Type       string   `json:"type"`   // factory, sysupgrade, ...
	Name       string   `json:"name"`
	HasFactory bool     `json:"hasFactory"` // the device has a plain "factory" image for the first flash
	Types      []string `json:"types"`
	Error      string   `json:"error"`
}

// CheckImage asks for the downloaded firmware file and checks it against the official checksums.
func (a *App) CheckImage(id, target string) ImageCheck {
	if a.ctx == nil {
		return ImageCheck{Error: "нет окна"}
	}
	path, err := runtime.OpenFileDialog(a.ctx, runtime.OpenDialogOptions{Title: "Скачанный файл прошивки OpenWrt"})
	if err != nil || path == "" {
		return ImageCheck{}
	}
	return checkImageFile(path, id, target)
}

func checkImageFile(path, id, target string) ImageCheck {
	ver, _, err := owLoad()
	if err != nil {
		return ImageCheck{Error: err.Error()}
	}
	var pj struct {
		Profiles map[string]struct {
			Images []struct {
				Name   string `json:"name"`
				Type   string `json:"type"`
				Sha256 string `json:"sha256"`
			} `json:"images"`
		} `json:"profiles"`
	}
	if err := owGet("/releases/"+ver+"/targets/"+target+"/profiles.json", &pj); err != nil {
		return ImageCheck{Error: "не удалось получить контрольные суммы OpenWrt: " + err.Error()}
	}
	prof, ok := pj.Profiles[id]
	if !ok {
		return ImageCheck{Error: "в данных OpenWrt нет устройства " + id}
	}
	f, err := os.Open(path)
	if err != nil {
		return ImageCheck{Error: "не открывается файл: " + err.Error()}
	}
	h := sha256.New()
	_, err = io.Copy(h, f)
	f.Close()
	if err != nil {
		return ImageCheck{Error: "не читается файл: " + err.Error()}
	}
	sum := hex.EncodeToString(h.Sum(nil))
	res := ImageCheck{}
	for _, im := range prof.Images {
		res.Types = append(res.Types, im.Type)
		if im.Type == "factory" {
			res.HasFactory = true
		}
		if strings.EqualFold(im.Sha256, sum) {
			res.OK, res.Type, res.Name = true, im.Type, im.Name
		}
	}
	return res
}
