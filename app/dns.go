package main

// Ready-made DNS services for ChatGPT and Claude, and a check from this PC: ask the service which address
// it gives for the site, then open the site through that address.
// The list was checked from a real router on 2026-11-09 (what opened through each service's node).

import (
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

// DNSPreset is one service the window offers.
type DNSPreset struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Note     string   `json:"note"`
	Services []string `json:"services"` // chatgpt, claude
	Kind     string   `json:"kind"`     // dot (Keenetic) | doh (OpenWrt) | zdns (Keenetic: Zapret DNS through the AI reserve, answers key ai_reserve)
	IP       string   `json:"ip"`
	SNI      string   `json:"sni"`
	DoH      string   `json:"doh"`
}

var dnsPresets = []DNSPreset{
	{ID: "geohide", Name: "GeoHide", Note: "ChatGPT, Claude и Gemini; 7 узлов — рекомендуется", Services: []string{"chatgpt", "claude"},
		Kind: "dot", IP: "5.175.161.3", SNI: "eu.geohide.ru"},
	{ID: "bezmezhau", Name: "Bezmezhau", Note: "только ChatGPT, один узел", Services: []string{"chatgpt"},
		Kind: "dot", IP: "143.20.64.55", SNI: "dns.bezmezhau.com"},
	{ID: "zapretdns", Name: "Zapret DNS", Note: "ChatGPT, Claude и Gemini — рекомендуется", Services: []string{"chatgpt", "claude"},
		Kind: "doh", DoH: "https://dns.zapret.moe/dns-query"},
	// Keenetic takes no DoH per domain from switchback: the AI reserve on the router asks Zapret DNS through zapret
	// and pins the addresses, with spare addresses and VPN behind it (lib/ai.sh). GeoHide went silent on 18.11.2026.
	{ID: "zapretdns-job", Name: "Zapret DNS", Note: "ChatGPT и Claude сразу: резерв для нейросетей — Zapret DNS, запасные адреса, VPN; роутер сам выбирает рабочий путь",
		Services: []string{"chatgpt", "claude"}, Kind: "zdns", DoH: "https://dns.zapret.moe/dns-query"},
}

// DNSPresets: the services that fit this firmware (Keenetic takes DoT, OpenWrt DoH).
func (a *App) DNSPresets(platform string) []DNSPreset {
	kind := "dot"
	if platform == "openwrt" {
		kind = "doh"
	}
	out := []DNSPreset{}
	for _, p := range dnsPresets {
		if p.Kind == kind || (kind == "dot" && p.Kind == "zdns") {
			out = append(out, p)
		}
	}
	return out
}

// DNSCheck goes back to the window.
type DNSCheck struct {
	OK    bool   `json:"ok"`
	Error string `json:"error"`
	Node  string `json:"node"` // the address the service gave
	Time  string `json:"time"` // seconds to open the site through it
}

var serviceHost = map[string]string{"chatgpt": "chatgpt.com", "claude": "claude.ai"}

// replaced in tests
var (
	dotPort  = "853"
	nodePort = "443"
	dnsHTTP  = &http.Client{Timeout: 10 * time.Second}
)

// CheckDNS asks the service (DoT: ip+sni, DoH: url) for the site of the service and opens it through that address.
func (a *App) CheckDNS(kind, ip, sni, doh, service string) DNSCheck {
	host := serviceHost[service]
	if host == "" {
		return DNSCheck{Error: "неизвестный сервис"}
	}
	var ips []string
	var err error
	switch kind {
	case "dot":
		if net.ParseIP(strings.TrimSpace(ip)) == nil || strings.TrimSpace(sni) == "" {
			return DNSCheck{Error: "Нужны IP и имя (SNI) DoT-сервера."}
		}
		ips, err = askDoT(strings.TrimSpace(ip), strings.TrimSpace(sni), host)
	case "doh":
		if !strings.HasPrefix(strings.TrimSpace(doh), "https://") {
			return DNSCheck{Error: "Адрес DoH должен начинаться с https://"}
		}
		ips, err = askDoH(strings.TrimSpace(doh), host)
	default:
		return DNSCheck{Error: "неизвестный вид DNS"}
	}
	if err != nil {
		return DNSCheck{Error: "DNS-сервис не ответил: " + err.Error()}
	}
	if len(ips) == 0 {
		return DNSCheck{Error: "DNS-сервис не дал адреса для " + host + "."}
	}
	// open the site through the first address that answers
	for _, n := range ips {
		t0 := time.Now()
		if code, err := openVia(n, host); err == nil && code > 0 {
			return DNSCheck{OK: true, Node: n, Time: fmt.Sprintf("%.1f", time.Since(t0).Seconds())}
		}
	}
	return DNSCheck{Error: "Сервис дал адрес (" + ips[0] + "), но " + host + " через него не открылся. Выберите другой сервис.", Node: ips[0]}
}

func dnsQuery(name string) []byte {
	q := []byte{0x42, 0x42, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0}
	for _, p := range strings.Split(name, ".") {
		q = append(q, byte(len(p)))
		q = append(q, p...)
	}
	return append(q, 0, 0, 1, 0, 1) // type A, class IN
}

// dnsAnswerIPs reads the A records of a DNS answer.
func dnsAnswerIPs(r []byte) ([]string, error) {
	if len(r) < 12 {
		return nil, fmt.Errorf("короткий ответ")
	}
	an := int(binary.BigEndian.Uint16(r[6:8]))
	i := 12
	skipName := func() error {
		for i < len(r) {
			l := int(r[i])
			if l&0xc0 == 0xc0 {
				i += 2
				return nil
			}
			i++
			if l == 0 {
				return nil
			}
			i += l
		}
		return fmt.Errorf("испорченный ответ")
	}
	if err := skipName(); err != nil {
		return nil, err
	}
	i += 4
	var out []string
	for k := 0; k < an; k++ {
		if err := skipName(); err != nil || i+10 > len(r) {
			return out, nil
		}
		typ := binary.BigEndian.Uint16(r[i : i+2])
		ln := int(binary.BigEndian.Uint16(r[i+8 : i+10]))
		i += 10
		if typ == 1 && ln == 4 && i+4 <= len(r) {
			out = append(out, net.IP(r[i:i+4]).String())
		}
		i += ln
	}
	return out, nil
}

func askDoT(ip, sni, host string) ([]string, error) {
	d := &net.Dialer{Timeout: 6 * time.Second}
	c, err := tls.DialWithDialer(d, "tcp", net.JoinHostPort(ip, dotPort), &tls.Config{ServerName: sni, InsecureSkipVerify: dotInsecure})
	if err != nil {
		return nil, err
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(8 * time.Second))
	q := dnsQuery(host)
	msg := append([]byte{byte(len(q) >> 8), byte(len(q))}, q...)
	if _, err := c.Write(msg); err != nil {
		return nil, err
	}
	var lb [2]byte
	if _, err := io.ReadFull(c, lb[:]); err != nil {
		return nil, err
	}
	r := make([]byte, int(lb[0])<<8|int(lb[1]))
	if _, err := io.ReadFull(c, r); err != nil {
		return nil, err
	}
	return dnsAnswerIPs(r)
}

var dotInsecure = false // tests only

func askDoH(url, host string) ([]string, error) {
	req, _ := http.NewRequest("GET", url+"?dns="+base64.RawURLEncoding.EncodeToString(dnsQuery(host)), nil)
	req.Header.Set("Accept", "application/dns-message")
	r, err := dnsHTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer r.Body.Close()
	if r.StatusCode != 200 {
		return nil, fmt.Errorf("код %d", r.StatusCode)
	}
	b, _ := io.ReadAll(io.LimitReader(r.Body, 64<<10))
	return dnsAnswerIPs(b)
}

// openVia opens https://host/ connecting to ip (any HTTP answer counts: the site itself answered).
func openVia(ip, host string) (int, error) {
	tr := &http.Transport{
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{Timeout: 6 * time.Second}).DialContext(ctx, network, net.JoinHostPort(ip, nodePort))
		},
		TLSClientConfig: &tls.Config{ServerName: host, InsecureSkipVerify: dotInsecure},
	}
	cl := &http.Client{Timeout: 10 * time.Second, Transport: tr,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	r, err := cl.Get("https://" + host + "/")
	if err != nil {
		return 0, err
	}
	r.Body.Close()
	return r.StatusCode, nil
}
