package main

// Installation from the window: answers -> router, installer runs detached from the SSH session,
// the program follows its log. Plus: checking the Telegram bot token and saving the snapshot.

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/wailsapp/wails/v2/pkg/runtime"
	"golang.org/x/crypto/ssh"
)

// Keys the window may send; the same list as ANSWER_KEYS in lib/common.sh (docs/answers.md).
var answerKeys = map[string]bool{
	"continue_with_warnings": true, "continue_with_problems": true, "profile": true, "modules": true, "start": true,
	"zapret_exclude_policy": true, "disable_offload": true, "no_quic": true,
	"dns_chatgpt": true, "dns_chatgpt_ip": true, "dns_chatgpt_sni": true, "dns_chatgpt_doh": true,
	"dns_claude": true, "dns_claude_ip": true, "dns_claude_sni": true, "dns_claude_doh": true, "ai_reserve": true,
	"vpn_iface": true, "meta_vpn": true, "replace_watchdog": true, "replace_backup": true, "bot_token": true, "bot_chat": true, "ntfy_url": true,
	"uninstall_confirm": true, "uninstall_packages": true, "uninstall_feeds": true,
	"failover_tunnels": true, "replace_failover": true, "replace_nodes": true, "replace_bot": true,
}

// buildAnswers turns the window's choices into an answers file. Values are single-line.
func buildAnswers(ans map[string]string) (string, error) {
	keys := make([]string, 0, len(ans))
	for k := range ans {
		if !answerKeys[k] {
			return "", fmt.Errorf("неизвестный ключ ответа: %s", k)
		}
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		v := strings.TrimSpace(ans[k])
		if strings.ContainsAny(v, "\r\n") {
			return "", fmt.Errorf("значение %s в несколько строк", k)
		}
		b.WriteString(k + "=" + v + "\n")
	}
	return b.String(), nil
}

// InstallResult goes back to the window when the installer has finished.
type InstallResult struct {
	OK       bool   `json:"ok"`
	Error    string `json:"error"`
	ExitCode int    `json:"exitCode"`
	Backup   string `json:"backup"` // snapshot folder on the router
	Name     string `json:"name"`   // WireGuard connection created by wg-import
}

// Install runs "install.sh install" with the given answers (dryRun: change nothing).
// Progress arrives as "sb:event" / "sb:log" window events, like Analyze.
func (a *App) Install(ans map[string]string, dryRun bool) InstallResult {
	text, err := buildAnswers(ans)
	if err != nil {
		return InstallResult{Error: err.Error()}
	}
	args := "install --answers @IN --progress"
	if dryRun {
		args += " --dry-run"
	}
	return a.runDetached(args, "answers", text)
}

// Uninstall undoes everything switchback changed ("Откатить всё"), detached like Install.
func (a *App) Uninstall(removePackages bool) InstallResult {
	ans := map[string]string{"uninstall_confirm": "y", "uninstall_packages": "n", "uninstall_feeds": "n"}
	if removePackages {
		ans["uninstall_packages"] = "y"
	}
	text, _ := buildAnswers(ans)
	return a.runDetached("uninstall --answers @IN --progress", "answers", text)
}

// runDetached uploads the installer, puts input (answers or a .conf: may hold secrets) into a private
// file @IN on the router, runs install.sh ARGS detached from the SSH session and follows its log.
func (a *App) runDetached(args, inName, input string) InstallResult {
	a.mu.Lock()
	c := a.client
	a.mu.Unlock()
	if c == nil {
		return InstallResult{Error: "Нет подключения к роутеру."}
	}
	res := InstallResult{ExitCode: -1}
	failMsg, ended, lastBad := "", false, ""
	onLine := func(line string) {
		ev, ok := parseEvent(line)
		if !ok {
			a.emit("sb:log", line)
			return
		}
		switch ev.Kind {
		case "item":
			if len(ev.Fields) > 1 && ev.Fields[0] == "bad" {
				lastBad = ev.Fields[1]
			}
		case "fail":
			if len(ev.Fields) > 0 {
				failMsg = ev.Fields[0]
			}
		case "backup":
			if len(ev.Fields) > 0 {
				res.Backup = ev.Fields[0]
			}
		case "wg":
			if len(ev.Fields) > 0 {
				res.Name = ev.Fields[0]
			}
		case "end", "exited":
			if !ended && len(ev.Fields) > 0 {
				fmt.Sscan(ev.Fields[0], &res.ExitCode)
			}
			ended = true
		}
		a.emit("sb:event", ev)
	}
	// fresh installer copy: the router may have rebooted since the analysis
	if err := uploadInstaller(c, a.remoteDir, func(l string) { a.emit("sb:log", l) }); err != nil {
		return InstallResult{Error: err.Error()}
	}
	code, err := runStream(c, detachedCommand(a.remoteDir, inName, args), strings.NewReader(input), onLine)
	switch {
	case err != nil:
		res.Error = "Связь с роутером оборвалась. Установка на роутере продолжается сама; при сбое она откатится. " +
			"Журнал: " + a.remoteDir + "/run.log"
	case failMsg != "":
		res.Error = failMsg
	case !ended:
		res.Error = fmt.Sprintf("Установщик завершился неожиданно (код %d), подробности в журнале.", code)
	case res.ExitCode != 0 && lastBad != "":
		res.Error = lastBad
	case res.ExitCode != 0:
		res.Error = "Остановлено (ответ «нет» на вопрос или неверные данные), подробности в журнале."
	default:
		res.OK = true
	}
	return res
}

// detachedCommand: save stdin to a private file (@IN in args) that the installer deletes as soon as it
// has read it (and is removed after the run in any case); start the installer detached from this SSH
// session (a lost connection must not cut it in half: it either finishes or rolls back by itself);
// follow its log until it exits.
func detachedCommand(dir, inName, args string) string {
	q := shellQuote(dir)
	in := q + "/" + inName
	args = strings.ReplaceAll(args, "@IN", in)
	// "a && b & c" would put a and b in the background too: finish the setup first
	return "umask 077 && cat > " + in + " && : > " + q + "/run.log || exit 97; " +
		"( trap '' HUP; SB_ANSWERS_RM=1 sh " + q + "/install.sh " + args + " < /dev/null > " + q + "/run.log 2>&1; " +
		"rc=$?; rm -f " + in + "; echo \"@@sb\texited\t$rc\" >> " + q + "/run.log ) & pid=$!; " +
		"tail -n +1 -f " + q + "/run.log & t=$!; " +
		"while kill -0 $pid 2>/dev/null; do sleep 1; done; sleep 1; kill $t 2>/dev/null; wait $pid"
}

// ---------- Telegram bot check (from the PC) ----------

// BotCheck goes back to the window. The token is never stored or logged.
type BotCheck struct {
	OK       bool   `json:"ok"`
	Error    string `json:"error"`
	Username string `json:"username"`
	Chat     string `json:"chat"` // chat id from the latest message to the bot, if any
}

var tokenRe = regexp.MustCompile(`^[0-9]{5,}:[A-Za-z0-9_-]{30,}$`)

// telegramAPI is replaced in tests.
var telegramAPI = "https://api.telegram.org"

func (a *App) CheckBot(token string) BotCheck {
	token = strings.TrimSpace(token)
	if !tokenRe.MatchString(token) {
		return BotCheck{Error: "Это не похоже на токен бота: он выглядит как 123456789:AA… (цифры, двоеточие, буквы)."}
	}
	cl := &http.Client{Timeout: 12 * time.Second}
	get := func(method string, v any) error {
		r, err := cl.Get(telegramAPI + "/bot" + token + "/" + method)
		if err != nil {
			return err
		}
		defer r.Body.Close()
		body, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		return json.Unmarshal(body, v)
	}
	var me struct {
		OK     bool `json:"ok"`
		Result struct {
			Username string `json:"username"`
		} `json:"result"`
	}
	if err := get("getMe", &me); err != nil {
		return BotCheck{Error: "Telegram не ответил с этого компьютера. Токен проверится на роутере во время установки."}
	}
	if !me.OK {
		return BotCheck{Error: "Telegram не принял токен: скопируйте его из @BotFather ещё раз."}
	}
	var up struct {
		OK     bool `json:"ok"`
		Result []struct {
			Message *struct {
				Chat struct {
					ID int64 `json:"id"`
				} `json:"chat"`
			} `json:"message"`
		} `json:"result"`
	}
	res := BotCheck{OK: true, Username: me.Result.Username}
	if get("getUpdates", &up) == nil && up.OK {
		for i := len(up.Result) - 1; i >= 0; i-- {
			if m := up.Result[i].Message; m != nil {
				res.Chat = fmt.Sprint(m.Chat.ID)
				break
			}
		}
	}
	if res.Chat == "" {
		res.Error = "Бот найден, но ещё не видит ваших сообщений: откройте @" + res.Username + ", нажмите Start, напишите что-нибудь и проверьте снова."
	}
	return res
}

// ---------- snapshot to the PC ----------

// SaveBackup asks where to save and downloads the router's snapshot folder as .tar.gz.
// The snapshot holds the router's settings (password hashes too): it stays on this PC.
func (a *App) SaveBackup(remote string) (string, error) {
	if a.ctx == nil {
		return "", fmt.Errorf("нет окна")
	}
	name := "switchback-snapshot-" + time.Now().Format("2006-01-02-1504") + ".tar.gz"
	path, err := runtime.SaveFileDialog(a.ctx, runtime.SaveDialogOptions{
		Title: "Сохранить снимок настроек роутера", DefaultFilename: name,
		Filters: []runtime.FileFilter{{DisplayName: "Архив (*.tar.gz)", Pattern: "*.tar.gz"}},
	})
	if err != nil || path == "" {
		return "", err
	}
	return path, a.downloadBackup(remote, path)
}

func (a *App) downloadBackup(remote, path string) error {
	a.mu.Lock()
	c := a.client
	a.mu.Unlock()
	if c == nil {
		return fmt.Errorf("нет подключения к роутеру")
	}
	if !strings.Contains(remote, "/switchback/backups/") {
		return fmt.Errorf("странный путь снимка: %s", remote) // only our own snapshot folders
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	code, err := runToWriter(c, "tar czf - -C "+shellQuote(remote)+" .", f)
	f.Close()
	if err == nil && code != 0 {
		err = fmt.Errorf("роутер не отдал снимок (код %d)", code)
	}
	if err != nil {
		os.Remove(path)
	}
	return err
}

// runToWriter runs cmd and copies its raw stdout to w (for binary data).
func runToWriter(c *ssh.Client, cmd string, w io.Writer) (int, error) {
	s, err := c.NewSession()
	if err != nil {
		return -1, err
	}
	defer s.Close()
	s.Stdout = w
	err = s.Run(cmd)
	if ee, ok := err.(*ssh.ExitError); ok {
		return ee.ExitStatus(), nil
	}
	if err != nil {
		return -1, err
	}
	return 0, nil
}

// ---------- diagnostic report ----------

// ReportResult goes back to the window.
type ReportResult struct {
	OK    bool   `json:"ok"`
	Error string `json:"error"`
	Path  string `json:"path"` // where it was saved on the PC ("" = not saved / cancelled)
}

// Report runs "install.sh report" (secrets are cut out on the router and checked again there) and
// asks where to save the text on the PC.
func (a *App) Report() ReportResult {
	text, err := a.reportText()
	if err != nil {
		return ReportResult{Error: err.Error()}
	}
	if a.ctx == nil {
		return ReportResult{Error: "нет окна"}
	}
	name := "switchback-report-" + time.Now().Format("2006-01-02-1504") + ".txt"
	path, err := runtime.SaveFileDialog(a.ctx, runtime.SaveDialogOptions{
		Title: "Сохранить отчёт для диагностики", DefaultFilename: name,
		Filters: []runtime.FileFilter{{DisplayName: "Текст (*.txt)", Pattern: "*.txt"}},
	})
	if err != nil || path == "" {
		return ReportResult{OK: true}
	}
	if err := os.WriteFile(path, []byte(strings.ReplaceAll(text, "\n", "\r\n")), 0o600); err != nil {
		return ReportResult{Error: "Не удалось сохранить: " + err.Error()}
	}
	return ReportResult{OK: true, Path: path}
}

// reportText uploads the installer and returns the report text (without event lines).
func (a *App) reportText() (string, error) {
	a.mu.Lock()
	c := a.client
	a.mu.Unlock()
	if c == nil {
		return "", fmt.Errorf("Нет подключения к роутеру.")
	}
	if err := uploadInstaller(c, a.remoteDir, func(string) {}); err != nil {
		return "", err
	}
	var b strings.Builder
	failMsg := ""
	code, err := runStream(c, "sh "+shellQuote(a.remoteDir+"/install.sh")+" report --progress", nil, func(line string) {
		if ev, ok := parseEvent(line); ok {
			if ev.Kind == "fail" && len(ev.Fields) > 0 {
				failMsg = ev.Fields[0]
			}
			return
		}
		b.WriteString(line + "\n")
	})
	if err != nil {
		return "", fmt.Errorf("Связь с роутером оборвалась: %v", err)
	}
	if failMsg != "" {
		return "", fmt.Errorf("%s", failMsg)
	}
	if code != 0 {
		return "", fmt.Errorf("Отчёт не собрался (код %d).", code)
	}
	return b.String(), nil
}
