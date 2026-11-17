package main

// The reserve notification channel ntfy: a random channel name, and a test message from this PC.

import (
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// same rule as ntfy_valid in lib/modules.sh (the program only makes ntfy.sh channels)
var ntfyRe = regexp.MustCompile(`^https://[a-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9_-]{12,64}$`)

// NewNtfyChannel: a long random name nobody can guess (whoever knows it can read the alerts).
func (a *App) NewNtfyChannel() string {
	b := make([]byte, 12)
	rand.Read(b)
	return "https://ntfy.sh/sb-" + hex.EncodeToString(b)
}

// ntfyClient is replaced in tests
var ntfyClient = &http.Client{Timeout: 12 * time.Second}

// TestNtfy sends a test notification from this PC ("" = sent).
func (a *App) TestNtfy(url string) string {
	url = strings.TrimSpace(url)
	if !ntfyRe.MatchString(url) {
		return "Странный адрес канала: нужен вида https://ntfy.sh/длинное-имя."
	}
	req, _ := http.NewRequest("POST", url, strings.NewReader("switchback: проверка с компьютера. Если вы это видите — запасной канал работает."))
	req.Header.Set("Title", "switchback")
	r, err := ntfyClient.Do(req)
	if err != nil {
		return "ntfy не ответил с этого компьютера. С роутера проверочное уведомление уйдёт ещё раз при установке."
	}
	r.Body.Close()
	if r.StatusCode != 200 {
		return "ntfy ответил кодом " + r.Status + "."
	}
	return ""
}
