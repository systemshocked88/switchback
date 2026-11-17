package main

// Hints about the firmware already on the router, from the analysis ("fw" event).

import (
	"net/url"
	"strconv"
	"strings"
)

// FirmwareAdvice goes back to the window ("" text = nothing to say).
type FirmwareAdvice struct {
	Text string `json:"text"`
	URL  string `json:"url"`  // where to get the newer firmware, if any
	Warn bool   `json:"warn"` // worth acting on (not only for information)
}

// verParts "24.10.4" -> [24 10 4]; ok=false for SNAPSHOT and the like
func verParts(v string) ([]int, bool) {
	var out []int
	for _, p := range strings.Split(strings.TrimSpace(v), ".") {
		n, err := strconv.Atoi(strings.TrimLeft(p, "v"))
		if err != nil {
			return nil, false
		}
		out = append(out, n)
	}
	return out, len(out) > 0
}

// olderThan: is a older than b (by numbers)
func olderThan(a, b []int) bool {
	for i := 0; i < len(a) || i < len(b); i++ {
		x, y := 0, 0
		if i < len(a) {
			x = a[i]
		}
		if i < len(b) {
			y = b[i]
		}
		if x != y {
			return x < y
		}
	}
	return false
}

func (a *App) FirmwareHint(platform, version, board string) FirmwareAdvice {
	switch platform {
	case "keenetic":
		v, ok := verParts(version)
		if ok && v[0] < 4 {
			return FirmwareAdvice{Text: "На роутере KeeneticOS " + version + ". С версии 4.x роутер сам пускает сайты через VPN по имени домена; " +
				"сейчас свои сайты через VPN идут по их адресам (switchback обновляет их каждые 5 минут) — это тоже работает. " +
				"Если для вашей модели есть 4.x, обновиться можно в веб-интерфейсе: Общие настройки → Обновление KeeneticOS. " +
				"После обновления прошивки запустите в программе анализ ещё раз."}
		}
		return FirmwareAdvice{}
	case "openwrt":
		have, ok := verParts(version)
		if !ok {
			if strings.Contains(strings.ToUpper(version), "SNAPSHOT") {
				return FirmwareAdvice{Text: "На роутере тестовая сборка OpenWrt (SNAPSHOT): в ней пакеты и настройки иногда меняются без предупреждения. Надёжнее — стабильная версия."}
			}
			return FirmwareAdvice{}
		}
		stable, profiles, err := owLoad()
		if err != nil {
			return FirmwareAdvice{}
		}
		last, ok := verParts(stable)
		if !ok || !olderThan(have, last) {
			return FirmwareAdvice{}
		}
		// the device in the firmware selector: board_name "xiaomi,mi-router-ax3000t" -> id "xiaomi_mi-router-ax3000t"
		q := url.Values{"version": {stable}}
		id := strings.ReplaceAll(strings.TrimSpace(board), ",", "_")
		for _, p := range profiles {
			if id != "" && p.ID == id {
				q.Set("target", p.Target)
				q.Set("id", p.ID)
				break
			}
		}
		text := "На роутере OpenWrt " + version + ", последняя стабильная — " + stable + ". Обновиться: скачайте файл sysupgrade для своей модели " +
			"(кнопка ниже) и загрузите его в LuCI → System → Backup / Flash Firmware. Настройки switchback сохранятся, " +
			"а пакеты (zapret и др.) после обновления поставит повторная установка — анализ это подскажет."
		if have[0] != last[0] {
			text += " Это переход через старшую версию (" + strconv.Itoa(have[0]) + " → " + strconv.Itoa(last[0]) + "): сначала прочитайте страницу устройства на openwrt.org — иногда так обновляться можно только без сохранения настроек."
		}
		return FirmwareAdvice{Text: text, URL: "https://firmware-selector.openwrt.org/?" + q.Encode(), Warn: true}
	}
	return FirmwareAdvice{}
}
