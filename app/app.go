package main

import (
	"context"
	"errors"
	"net"
	"strconv"
	"sync"

	"github.com/wailsapp/wails/v2/pkg/runtime"
	"golang.org/x/crypto/ssh"
)

const appVersion = "0.7.7"

// App holds the methods the window can call (window.go.main.App.*).
type App struct {
	ctx    context.Context
	mu     sync.Mutex
	client *ssh.Client
	host   string
	port   int
	kh     *knownHosts

	remoteDir string                         // where the installer goes on the router
	emit      func(name string, data any)    // window events; replaced in tests
}

func NewApp() *App {
	a := &App{kh: defaultKnownHosts(), remoteDir: defaultRemoteDir}
	a.emit = func(name string, data any) {
		if a.ctx != nil {
			runtime.EventsEmit(a.ctx, name, data)
		}
	}
	return a
}

func (a *App) startup(ctx context.Context) { a.ctx = ctx }

func (a *App) shutdown(context.Context) { a.Disconnect() }

func (a *App) Version() string { return appVersion }

// ConnectResult goes back to the window after Connect.
type ConnectResult struct {
	OK          bool   `json:"ok"`
	Error       string `json:"error"`
	Fingerprint string `json:"fingerprint"`
	NewKey      bool   `json:"newKey"`
	KeyChanged  bool   `json:"keyChanged"`
}

// Connect logs in to the router. The password is used only for this login and never stored.
func (a *App) Connect(host string, port int, user, password string) ConnectResult {
	a.Disconnect()
	if port <= 0 {
		port = 22
	}
	c, info, err := dialRouter(host, port, user, password, a.kh)
	password = ""
	if err != nil {
		return ConnectResult{Error: friendlyError(err, host, port), Fingerprint: info.Fingerprint,
			KeyChanged: errors.Is(err, errHostKeyChanged)}
	}
	a.mu.Lock()
	a.client, a.host, a.port = c, host, port
	a.mu.Unlock()
	return ConnectResult{OK: true, Fingerprint: info.Fingerprint, NewKey: info.NewKey}
}

// ForgetKey drops the remembered key of host:port (after a router reset).
func (a *App) ForgetKey(host string, port int) error {
	if port <= 0 {
		port = 22
	}
	return a.kh.forget(net.JoinHostPort(host, strconv.Itoa(port)))
}

func (a *App) Disconnect() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.client != nil {
		a.client.Close()
		a.client = nil
	}
}

// AnalyzeResult goes back to the window after Analyze.
type AnalyzeResult struct {
	OK       bool   `json:"ok"`
	Error    string `json:"error"`
	ExitCode int    `json:"exitCode"`
}

// Analyze uploads the installer and runs "install.sh doctor --progress".
// Progress arrives as window events: "sb:event" (parsed @@sb lines) and "sb:log" (all other lines).
// Doctor changes nothing on the router.
func (a *App) Analyze() AnalyzeResult { return a.runReport("doctor", "doctor") }

// Status runs "install.sh status --progress": what switchback installed and whether it works. Changes nothing.
func (a *App) Status() AnalyzeResult { return a.runReport("status", "status") }

// runReport runs a read-only installer command whose exit code is a verdict 0/1/2,
// announced by the verdictEvent line.
func (a *App) runReport(cmd, verdictEvent string) AnalyzeResult {
	a.mu.Lock()
	c := a.client
	a.mu.Unlock()
	if c == nil {
		return AnalyzeResult{Error: "Нет подключения к роутеру."}
	}
	failMsg, sawVerdict := "", false
	onLine := func(line string) {
		if ev, ok := parseEvent(line); ok {
			switch ev.Kind {
			case "fail":
				if len(ev.Fields) > 0 {
					failMsg = ev.Fields[0]
				}
			case verdictEvent:
				sawVerdict = true
			}
			a.emit("sb:event", ev)
		} else {
			a.emit("sb:log", line)
		}
	}
	if err := uploadInstaller(c, a.remoteDir, onLine); err != nil {
		return AnalyzeResult{Error: err.Error()}
	}
	code, err := runStream(c, "sh "+shellQuote(a.remoteDir+"/install.sh")+" "+cmd+" --progress", nil, onLine)
	if err != nil {
		return AnalyzeResult{Error: "Связь с роутером оборвалась: " + err.Error()}
	}
	// doctor's exit code is its verdict (0/1/2), but 1 is also "failed": trust the events
	if failMsg != "" {
		return AnalyzeResult{Error: failMsg, ExitCode: code}
	}
	if !sawVerdict || code > 2 || code < 0 {
		return AnalyzeResult{Error: "Анализ не выполнился (код " + strconv.Itoa(code) + "), подробности в журнале.", ExitCode: code}
	}
	return AnalyzeResult{OK: true, ExitCode: code}
}
