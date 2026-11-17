package main

// WireGuard from a .conf file: the file goes to the router only (keys included), where
// "install.sh wg-import" creates the connection and deletes the copy right after reading it.

import (
	"fmt"
	"os"
	"strings"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// ImportWireGuard asks for a .conf file and creates the connection on the router. standby: a reserve
// tunnel kept switched off (the failover switches it on when the main one stops working).
func (a *App) ImportWireGuard(standby bool) InstallResult {
	if a.ctx == nil {
		return InstallResult{Error: "нет окна"}
	}
	path, err := runtime.OpenFileDialog(a.ctx, runtime.OpenDialogOptions{
		Title:   "Файл WireGuard от VPN-сервиса",
		Filters: []runtime.FileFilter{{DisplayName: "WireGuard (*.conf)", Pattern: "*.conf"}},
	})
	if err != nil || path == "" {
		return InstallResult{Error: ""} // cancelled
	}
	return a.importWireGuardFile(path, standby)
}

func (a *App) importWireGuardFile(path string, standby bool) InstallResult {
	st, err := os.Stat(path)
	if err != nil {
		return InstallResult{Error: "Не открывается файл: " + err.Error()}
	}
	if st.Size() > 64*1024 {
		return InstallResult{Error: "Файл слишком большой для конфига WireGuard."}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return InstallResult{Error: "Не читается файл: " + err.Error()}
	}
	text := string(data)
	if err := checkWGConf(text); err != nil {
		return InstallResult{Error: err.Error()}
	}
	args := "wg-import --conf @IN --progress"
	if standby {
		args += " --standby"
	}
	return a.runDetached(args, "wg.conf", text)
}

// checkWGConf: a quick look before sending (the router checks it fully). Never echoes the content.
func checkWGConf(s string) error {
	low := strings.ToLower(s)
	for _, need := range []string{"[interface]", "privatekey", "[peer]", "publickey", "endpoint"} {
		if !strings.Contains(low, need) {
			return fmt.Errorf("Это не похоже на конфиг WireGuard: нет строки %q. Нужен файл .conf от VPN-сервиса.", need)
		}
	}
	return nil
}
