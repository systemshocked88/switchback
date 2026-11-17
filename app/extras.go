package main

// Own sites, switchback update and zapret tuning from the window (install.sh sites / update / tune).

import (
	"fmt"
	"regexp"
	"strings"
)

// SiteInfo / SitesInfo go back to the window.
type SiteInfo struct {
	Way    string `json:"way"` // zapret | dns | vpn
	Domain string `json:"domain"`
}
type SitesInfo struct {
	OK      bool       `json:"ok"`
	Error   string     `json:"error"`
	Sites   []SiteInfo `json:"sites"`
	Zapret  bool       `json:"zapret"`  // zapret is installed: the zapret way is available
	DNS     []string   `json:"dns"`     // services with a DNS server the dns way can reuse (claude.ai, chatgpt.com)
	DNSFree int        `json:"dnsFree"` // DNS records the router still accepts
	Tunnel  string     `json:"tunnel"`  // the tunnel for the vpn way ("" = none)
}

var siteRe = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$`)

// normSite: what people paste (https://www.Site.com/page) -> site.com; "" if it is not a site address.
// Same rules as site_norm/site_valid in lib/sites.sh.
func normSite(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	if i := strings.Index(s, "://"); i >= 0 {
		s = s[i+3:]
	}
	if i := strings.IndexAny(s, "/?:#"); i >= 0 {
		s = s[:i]
	}
	s = strings.TrimSuffix(strings.TrimPrefix(s, "www."), ".")
	if len(s) > 253 || !siteRe.MatchString(s) {
		return ""
	}
	return s
}

// runQuick runs a short installer command (not detached), passes its events to the window and returns them.
func (a *App) runQuick(args string) ([]sbEvent, string, error) {
	a.mu.Lock()
	c := a.client
	a.mu.Unlock()
	if c == nil {
		return nil, "", fmt.Errorf("Нет подключения к роутеру.")
	}
	if err := uploadInstaller(c, a.remoteDir, func(l string) { a.emit("sb:log", l) }); err != nil {
		return nil, "", err
	}
	var evs []sbEvent
	lastBad := ""
	_, err := runStream(c, "sh "+shellQuote(a.remoteDir+"/install.sh")+" "+args+" --progress", nil, func(line string) {
		ev, ok := parseEvent(line)
		if !ok {
			a.emit("sb:log", line)
			return
		}
		if ev.Kind == "item" && len(ev.Fields) > 1 && ev.Fields[0] == "bad" {
			lastBad = ev.Fields[1]
		}
		evs = append(evs, ev)
		a.emit("sb:event", ev)
	})
	if err != nil {
		return nil, "", fmt.Errorf("Связь с роутером оборвалась: %v", err)
	}
	return evs, lastBad, nil
}

// Sites lists own sites and what each way needs.
func (a *App) Sites() SitesInfo {
	evs, bad, err := a.runQuick("sites list")
	if err != nil {
		return SitesInfo{Error: err.Error()}
	}
	r := SitesInfo{OK: true, Sites: []SiteInfo{}, DNS: []string{}}
	for _, e := range evs {
		f := e.Fields
		switch {
		case e.Kind == "site" && len(f) >= 2:
			r.Sites = append(r.Sites, SiteInfo{Way: f[0], Domain: f[1]})
		case e.Kind == "site_way" && len(f) >= 1 && f[0] == "zapret":
			r.Zapret = true
		case e.Kind == "site_way" && len(f) >= 2 && f[0] == "vpn":
			r.Tunnel = f[1]
		case e.Kind == "site_dns" && len(f) >= 1:
			r.DNS = append(r.DNS, f[0])
		case e.Kind == "site_dnsfree" && len(f) >= 1:
			fmt.Sscan(f[0], &r.DNSFree)
		case e.Kind == "fail" && len(f) >= 1:
			r.OK, r.Error = false, f[0]
		}
	}
	if !r.OK && r.Error == "" {
		r.Error = bad
	}
	return r
}

// SiteAdd puts a site into the bypass by the chosen way. Detached: it changes router settings.
func (a *App) SiteAdd(site, way string) InstallResult {
	d := normSite(site)
	if d == "" {
		return InstallResult{Error: "Это не похоже на адрес сайта: нужно вроде example.com."}
	}
	if way != "zapret" && way != "dns" && way != "vpn" {
		return InstallResult{Error: "Неизвестный способ: " + way}
	}
	return a.runDetached("sites add "+d+" --via "+way+" --progress", "answers", "")
}

// SiteDel takes a site added through "Свои сайты" out again.
func (a *App) SiteDel(site string) InstallResult {
	d := normSite(site)
	if d == "" {
		return InstallResult{Error: "Это не похоже на адрес сайта."}
	}
	return a.runDetached("sites del "+d+" --progress", "answers", "")
}

// SiteCheck: does the site open from the router now. Changes nothing.
type SiteCheckResult struct {
	OK    bool   `json:"ok"`
	Error string `json:"error"`
	Opens bool   `json:"opens"`
	Code  string `json:"code"`
	Time  string `json:"time"` // seconds
}

func (a *App) SiteCheck(site string) SiteCheckResult {
	d := normSite(site)
	if d == "" {
		return SiteCheckResult{Error: "Это не похоже на адрес сайта: нужно вроде example.com."}
	}
	evs, bad, err := a.runQuick("sites check " + d)
	if err != nil {
		return SiteCheckResult{Error: err.Error()}
	}
	for _, e := range evs {
		if e.Kind == "site_check" && len(e.Fields) >= 4 {
			return SiteCheckResult{OK: true, Opens: e.Fields[1] == "ok", Code: e.Fields[2], Time: e.Fields[3]}
		}
	}
	if bad == "" {
		bad = "Проверка не удалась."
	}
	return SiteCheckResult{Error: bad}
}

// Update replaces switchback's copy on the router and the scripts it installed with this version.
func (a *App) Update() InstallResult {
	return a.runDetached("update --progress", "answers", "")
}

// Tune tries zapret's ways and writes the best ones (undo: back to the settings before the last tune).
func (a *App) Tune(undo bool) InstallResult {
	args := "tune --progress"
	if undo {
		args += " --undo"
	}
	return a.runDetached(args, "answers", "")
}

// TuneVideo turns on or off zapret's own ways for YouTube video servers (install.sh tune video on|off).
func (a *App) TuneVideo(on bool) InstallResult {
	act := "off"
	if on {
		act = "on"
	}
	return a.runDetached("tune video "+act+" --progress", "answers", "")
}
