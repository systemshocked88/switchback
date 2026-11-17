package main

// "Which router is this?" without a password: most home routers announce themselves on the home network
// (UPnP, SSDP). The program asks who is an internet gateway, reads the device description the router
// publishes (maker, model, number) and guesses the firmware family. Nothing is changed on the router.

import (
	"encoding/xml"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// RouterGuess goes back to the window.
type RouterGuess struct {
	Found        bool   `json:"found"`
	Error        string `json:"error"`
	Address      string `json:"address"`      // the router's IP
	Manufacturer string `json:"manufacturer"`
	Model        string `json:"model"`        // model name and number as the router tells them
	Name         string `json:"name"`         // its friendly name
	Firmware     string `json:"firmware"`     // keenetic | openwrt | other
	Query        string `json:"query"`        // what to look up in the OpenWrt device list
}

var ssdpTargets = []string{"urn:schemas-upnp-org:device:InternetGatewayDevice:1", "upnp:rootdevice"}

// ssdpWait is how long answers are collected (replaced in tests)
var ssdpWait = 3 * time.Second

func (a *App) DetectRouter() RouterGuess {
	locs := ssdpSearch()
	if len(locs) == 0 {
		return RouterGuess{Error: "Не получилось узнать модель роутера автоматически (он не ответил на запрос; так бывает, если на нём выключен UPnP). Это не ошибка: посмотрите на наклейку снизу роутера и выберите ниже. Keenetic или Netcraze — первая вкладка. Другая марка (TP-Link, Xiaomi, Tenda, Asus…) — вкладка «Другая / не знаю»: введите модель с наклейки, и программа скажет, подойдёт ли роутер."}
	}
	var best RouterGuess
	bestScore := -1
	for _, loc := range locs {
		d, err := fetchDescription(loc)
		if err != nil {
			continue
		}
		g := guessFrom(d, loc)
		if s := d.score(); s > bestScore {
			best, bestScore = g, s
		}
	}
	if bestScore < 0 {
		return RouterGuess{Error: "Роутер ответил, но не сообщил свою модель. Выберите прошивку вручную."}
	}
	return best
}

// ssdpSearch sends M-SEARCH and returns the description URLs (LOCATION) of devices on the home network.
func ssdpSearch() []string {
	c, err := net.ListenUDP("udp4", &net.UDPAddr{})
	if err != nil {
		return nil
	}
	defer c.Close()
	dst := &net.UDPAddr{IP: net.IPv4(239, 255, 255, 250), Port: 1900}
	for _, st := range ssdpTargets {
		msg := "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: " + st + "\r\n\r\n"
		c.WriteToUDP([]byte(msg), dst)
	}
	seen := map[string]bool{}
	var locs []string
	buf := make([]byte, 4096)
	deadline := time.Now().Add(ssdpWait)
	for {
		c.SetReadDeadline(deadline)
		n, from, err := c.ReadFromUDP(buf)
		if err != nil {
			break
		}
		loc := ssdpLocation(string(buf[:n]))
		if loc == "" || seen[loc] || !localURL(loc, from.IP) {
			continue
		}
		seen[loc] = true
		locs = append(locs, loc)
	}
	return locs
}

func ssdpLocation(resp string) string {
	for _, l := range strings.Split(resp, "\n") {
		if k, v, ok := strings.Cut(l, ":"); ok && strings.EqualFold(strings.TrimSpace(k), "location") {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// localURL: only plain http to the very device that answered, on a private address (never fetch anything
// an answer points to elsewhere).
func localURL(loc string, from net.IP) bool {
	u, err := url.Parse(loc)
	if err != nil || u.Scheme != "http" {
		return false
	}
	ip := net.ParseIP(u.Hostname())
	return ip != nil && ip.Equal(from) && ip.IsPrivate()
}

type upnpDevice struct {
	DeviceType   string `xml:"deviceType"`
	FriendlyName string `xml:"friendlyName"`
	Manufacturer string `xml:"manufacturer"`
	ModelName    string `xml:"modelName"`
	ModelNumber  string `xml:"modelNumber"`
	ModelDesc    string `xml:"modelDescription"`
}

func (d upnpDevice) score() int {
	s := 0
	if strings.Contains(d.DeviceType, "InternetGatewayDevice") {
		s += 10
	}
	if d.ModelName != "" {
		s += 2
	}
	if d.Manufacturer != "" {
		s++
	}
	return s
}

func fetchDescription(loc string) (upnpDevice, error) {
	cl := &http.Client{Timeout: 3 * time.Second}
	r, err := cl.Get(loc)
	if err != nil {
		return upnpDevice{}, err
	}
	defer r.Body.Close()
	return parseDescription(io.LimitReader(r.Body, 64<<10))
}

func parseDescription(r io.Reader) (upnpDevice, error) {
	var root struct {
		Device upnpDevice `xml:"device"`
	}
	err := xml.NewDecoder(r).Decode(&root)
	return root.Device, err
}

var spaces = regexp.MustCompile(`\s+`)

func guessFrom(d upnpDevice, loc string) RouterGuess {
	clean := func(s string) string { return strings.TrimSpace(spaces.ReplaceAllString(s, " ")) }
	g := RouterGuess{Found: true, Manufacturer: clean(d.Manufacturer), Name: clean(d.FriendlyName)}
	if u, err := url.Parse(loc); err == nil {
		g.Address = u.Hostname()
	}
	// model: name + number, without repeating words (routers often put "Archer C6" and "C6" or "v3")
	parts := []string{}
	for _, w := range strings.Fields(clean(d.ModelName) + " " + clean(d.ModelNumber)) {
		dup := false
		for _, p := range parts {
			if strings.EqualFold(p, w) {
				dup = true
			}
		}
		if !dup {
			parts = append(parts, w)
		}
	}
	g.Model = strings.Join(parts, " ")
	all := strings.ToLower(strings.Join([]string{d.Manufacturer, d.ModelName, d.ModelNumber, d.FriendlyName, d.ModelDesc}, " "))
	switch {
	case strings.Contains(all, "keenetic") || strings.Contains(all, "netcraze"):
		g.Firmware = "keenetic"
	case strings.Contains(all, "openwrt") || strings.Contains(all, "immortalwrt") || strings.Contains(all, "istoreos"):
		g.Firmware = "openwrt"
	default:
		g.Firmware = "other"
	}
	// for the OpenWrt device list: the maker (without "Co., Ltd" and the like) and the model
	maker := strings.Fields(strings.NewReplacer(",", " ", ".", " ").Replace(g.Manufacturer))
	q := g.Model
	// (on OpenWrt the "maker" is OpenWrt itself, not the hardware maker)
	if len(maker) > 0 && g.Firmware != "openwrt" && !strings.Contains(strings.ToLower(q), strings.ToLower(maker[0])) {
		q = maker[0] + " " + q
	}
	g.Query = strings.TrimSpace(q)
	return g
}
