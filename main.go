// amp-rex-hud is a terminal HUD for Amp usage and the Amp agents running in
// Rex panes. Run it in a Rex split; see init.lua for a toggle key.
package main

import (
	"context"
	"encoding/base64"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

type config struct {
	usageEvery  time.Duration
	threadEvery time.Duration
	lowCredits  float64
	notify      bool
	client      string
}

func main() {
	var cfg config
	flag.DurationVar(&cfg.usageEvery, "usage-every", 3*time.Minute, "how often to run `amp usage` (Amp allows 60 usage lookups an hour)")
	flag.DurationVar(&cfg.threadEvery, "threads-every", 30*time.Second, "how often to list Amp threads")
	flag.Float64Var(&cfg.lowCredits, "low", 2, "alert when credits fall below this many dollars (0 turns it off)")
	flag.BoolVar(&cfg.notify, "notify", true, "send a macOS notification when an agent finishes or needs you")
	flag.StringVar(&cfg.client, "client", os.Getenv("REX_CLIENT"), "Rex app client to show focused panes in (label or ID); empty picks the only app")
	once := flag.Bool("once", false, "print one plain-text frame and exit")
	flag.Parse()

	// A Rex pane started without a shell doesn't get the login PATH, so add
	// where amp and rex are usually installed.
	home, _ := os.UserHomeDir()
	os.Setenv("PATH", strings.Join([]string{
		os.Getenv("PATH"), home + "/.local/bin", home + "/.amp/bin", os.Getenv("REX_BIN_DIR"), "/opt/homebrew/bin",
	}, ":"))

	m := newModel(cfg)
	if *once {
		ctx := context.Background()
		m.rex, m.rexErr = fetchRex(ctx, discoverHosts(ctx))
		m.usage, m.usageErr = fetchUsage(ctx)
		m.threads, m.threadsErr = fetchThreads(ctx, 15)
		m.remote, m.remoteErr = fetchBridge(ctx)
		m.width, m.height = 80, 60
		fmt.Println(m.View())
		return
	}
	if _, err := tea.NewProgram(m, tea.WithAltScreen()).Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

type (
	rexMsg struct {
		snap         RexSnapshot
		err          error
		hostsChecked bool // snap.Hosts came from a fresh discoverHosts
	}
	usageMsg struct {
		u   Usage
		err error
	}
	bridgeMsg struct {
		ts  []RemoteThread
		err error
	}
	threadsMsg struct {
		ts  []Thread
		err error
	}
	rexChangedMsg struct{}
	tickMsg       time.Time
	focusedMsg    struct{ err error }
)

type model struct {
	cfg     config
	ctx     context.Context
	changed chan struct{}

	rex        RexSnapshot
	rexErr     error
	usage      Usage
	usageErr   error
	threads    []Thread
	threadsErr error
	remote     []RemoteThread
	remoteErr  error

	cursor      int
	width       int
	height      int
	status      string
	lastUsage   time.Time
	lastThreads time.Time
	lowAlerted  bool
	rexLoading  bool
	hosts       []Host
	hostsAt     time.Time
	watching    map[string]bool // servers with a running watchRex
}

func newModel(cfg config) *model {
	return &model{cfg: cfg, ctx: context.Background(), changed: make(chan struct{}, 1)}
}

func (m *model) Init() tea.Cmd {
	m.rexLoading = true
	return tea.Batch(m.loadRex(), m.loadUsage(), m.loadThreads(), m.loadBridge(), m.waitChange(), tick())
}

func tick() tea.Cmd {
	return tea.Tick(5*time.Second, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m *model) waitChange() tea.Cmd {
	return func() tea.Msg {
		<-m.changed
		time.Sleep(300 * time.Millisecond) // let a burst of events settle
		return rexChangedMsg{}
	}
}

func (m *model) loadRex() tea.Cmd {
	// Hosts change rarely, so look them up again only once a minute.
	hosts, stale := m.hosts, time.Since(m.hostsAt) >= time.Minute
	return func() tea.Msg {
		if stale {
			hosts = discoverHosts(m.ctx)
		}
		s, err := fetchRex(m.ctx, hosts)
		return rexMsg{s, err, stale}
	}
}

func (m *model) loadUsage() tea.Cmd {
	m.lastUsage = time.Now()
	return func() tea.Msg { u, err := fetchUsage(m.ctx); return usageMsg{u, err} }
}

func (m *model) loadBridge() tea.Cmd {
	return func() tea.Msg { ts, err := fetchBridge(m.ctx); return bridgeMsg{ts, err} }
}

// remoteAgents are the bridge's threads that aren't already shown as a Rex
// pane. Amp puts the thread title in the pane title, so titles match them.
func (m *model) remoteAgents() []RemoteThread {
	inPane := map[string]bool{}
	for _, p := range m.agents() {
		if t := m.threadTitleFor(p); t != "" {
			inPane[t] = true
		}
	}
	var out []RemoteThread
	for _, t := range m.remote {
		if !inPane[t.Title] {
			out = append(out, t)
		}
	}
	return out
}

// alertRemote notifies when a thread outside Rex finishes or needs you.
func (m *model) alertRemote(cur []RemoteThread) {
	if m.remote == nil {
		return
	}
	prev := map[string]string{}
	for _, t := range m.remote {
		prev[t.ID] = t.State
	}
	shown := map[string]bool{}
	for _, t := range m.remoteAgents() {
		shown[t.ID] = true
	}
	for _, t := range cur {
		was, ok := prev[t.ID]
		if !ok || was == t.State || !shown[t.ID] {
			continue
		}
		switch {
		case t.State == "awaiting-approval":
			m.notify("Amp needs you", t.Title, "waiting for approval")
		case t.State == "error":
			m.notify("Amp failed", t.Title, "")
		case t.State == "idle" && was == "running":
			m.notify("Amp finished", t.Title, "")
		}
	}
}

func (m *model) loadThreads() tea.Cmd {
	m.lastThreads = time.Now()
	return func() tea.Msg { ts, err := fetchThreads(m.ctx, 15); return threadsMsg{ts, err} }
}

func (m *model) agents() []Pane {
	var out []Pane
	for _, p := range m.rex.Panes {
		if p.IsAmp() {
			out = append(out, p)
		}
	}
	return out
}

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height

	case tea.KeyMsg:
		agents := m.agents()
		switch msg.String() {
		case "q", "ctrl+c", "esc":
			return m, tea.Quit
		case "j", "down":
			if m.cursor < len(agents)-1 {
				m.cursor++
			}
		case "k", "up":
			if m.cursor > 0 {
				m.cursor--
			}
		case "enter", "f":
			if m.cursor < len(agents) {
				p := agents[m.cursor]
				m.status = "Showing " + paneName(p) + "…"
				return m, func() tea.Msg { return focusedMsg{focusPane(m.ctx, p, m.cfg.client)} }
			}
		case "r":
			m.status = "Refreshing…"
			m.rexLoading = true
			return m, tea.Batch(m.loadRex(), m.loadUsage(), m.loadThreads())
		}

	case focusedMsg:
		m.status = ""
		if msg.err != nil {
			m.status = "Focused the pane, but couldn't switch session (turn on Remote Control, pass -client): " + msg.err.Error()
		}

	case rexChangedMsg:
		cmds := []tea.Cmd{m.waitChange()}
		if !m.rexLoading {
			m.rexLoading = true
			cmds = append(cmds, m.loadRex())
		}
		return m, tea.Batch(cmds...)

	case rexMsg:
		m.rexLoading = false
		m.rexErr = msg.err
		if msg.hostsChecked {
			m.hosts, m.hostsAt = msg.snap.Hosts, time.Now()
			if m.watching == nil {
				m.watching = map[string]bool{}
			}
			for _, h := range m.hosts {
				if !m.watching[h.Server] {
					m.watching[h.Server] = true
					go watchRex(m.ctx, h.Server, m.changed)
				}
			}
		}
		if msg.err == nil {
			m.alertTransitions(m.rex, msg.snap)
			m.rex = msg.snap
			if n := len(m.agents()); m.cursor >= n && n > 0 {
				m.cursor = n - 1
			}
		}

	case usageMsg:
		if m.status == "Refreshing…" {
			m.status = ""
		}
		m.usageErr = msg.err
		if msg.err == nil {
			m.usage = msg.u
			m.alertLowCredits()
		}

	case threadsMsg:
		m.threadsErr = msg.err
		if msg.err == nil {
			m.threads = msg.ts
		}

	case bridgeMsg:
		m.remoteErr = msg.err
		if msg.err == nil {
			m.alertRemote(msg.ts)
			m.remote = msg.ts
		}

	case tickMsg:
		cmds := []tea.Cmd{tick(), m.loadBridge()}
		if time.Since(m.lastUsage) >= m.cfg.usageEvery {
			cmds = append(cmds, m.loadUsage())
		}
		if time.Since(m.lastThreads) >= m.cfg.threadEvery {
			cmds = append(cmds, m.loadThreads())
		}
		// Rex events cover most changes; this catches the rest, such as titles.
		if !m.rexLoading && time.Since(m.rex.At) >= 15*time.Second {
			m.rexLoading = true
			cmds = append(cmds, m.loadRex())
		}
		return m, tea.Batch(cmds...)
	}
	return m, nil
}

// alertTransitions notifies when an Amp agent finishes or starts waiting on you.
func (m *model) alertTransitions(old, cur RexSnapshot) {
	if old.At.IsZero() {
		return // first snapshot: nothing changed yet
	}
	prev := map[string]string{}
	for _, p := range old.Panes {
		prev[p.BlockID] = p.State
	}
	for _, p := range cur.Panes {
		if !p.IsAmp() || p.State == prev[p.BlockID] {
			continue
		}
		switch p.State {
		case "done":
			m.notify("Amp finished", paneName(p), p.Msg)
		case "blocked":
			m.notify("Amp needs you", paneName(p), firstNonEmpty(p.Msg, p.Kind))
		case "error":
			m.notify("Amp failed", paneName(p), p.Msg)
		}
	}
}

func (m *model) alertLowCredits() {
	if m.cfg.lowCredits <= 0 || m.usage.CreditsUSD < 0 {
		return
	}
	low := m.usage.CreditsUSD < m.cfg.lowCredits
	if low && !m.lowAlerted {
		m.notify("Amp credits low", fmt.Sprintf("$%.2f remaining", m.usage.CreditsUSD), "")
	}
	m.lowAlerted = low
}

func (m *model) notify(title, subtitle, body string) {
	// Report it to Rex too, so the HUD's own tab shows the alert when unfocused.
	text := strings.TrimSpace(title + ": " + subtitle + " " + body)
	fmt.Fprintf(os.Stdout, "\x1b]7501;state=done:app=amp-rex-hud:msg=%s\x1b\\", base64.StdEncoding.EncodeToString([]byte(text)))
	if !m.cfg.notify {
		return
	}
	script := fmt.Sprintf("display notification %q with title %q subtitle %q", body, title, subtitle)
	_ = exec.Command("osascript", "-e", script).Start()
}

func firstNonEmpty(s ...string) string {
	for _, v := range s {
		if v != "" {
			return v
		}
	}
	return ""
}
