// rex-hud is a terminal HUD for Amp, Claude, and Codex usage and the coding agents (Amp,
// Claude Code, Codex, Foundation Models chats) running in Rex panes and in the Claude and ChatGPT
// desktop apps. Run it in a Rex split; see init.lua for a toggle key.
package main

import (
	"context"
	"encoding/base64"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"runtime"
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
	stream      bool // -json: stdout carries JSON lines only
	amp         bool // the amp CLI is installed; without it the HUD hides Amp usage, threads, and the bridge
}

func main() {
	var cfg config
	flag.DurationVar(&cfg.usageEvery, "usage-every", 3*time.Minute, "how often to check Amp, Claude, and Codex usage (Amp allows 60 usage lookups an hour)")
	flag.DurationVar(&cfg.threadEvery, "threads-every", 30*time.Second, "how often to list Amp threads")
	flag.Float64Var(&cfg.lowCredits, "low", 2, "alert when credits fall below this many dollars (0 turns it off)")
	flag.BoolVar(&cfg.notify, "notify", true, "send a macOS notification when an agent finishes or needs you")
	flag.StringVar(&cfg.client, "client", os.Getenv("REX_CLIENT"), "Rex app client to show focused panes in (label or ID); empty picks the only app")
	once := flag.Bool("once", false, "print one plain-text frame and exit")
	asJSON := flag.Bool("json", false, "run without a screen: write snapshots as JSON lines and read commands from stdin (see stream.go)")
	cmdJSON := flag.String("cmd", "", "with -once -json: run one command, such as {\"op\":\"focus\",\"block\":\"…\"}, instead of writing a snapshot")
	flag.Parse()

	// A Rex pane started without a shell, or the notch app, doesn't get the
	// login PATH, so add where amp and rex are usually installed.
	home, _ := os.UserHomeDir()
	os.Setenv("PATH", strings.Join([]string{
		os.Getenv("PATH"), home + "/.local/bin", home + "/.amp/bin", os.Getenv("REX_BIN_DIR"), "/opt/homebrew/bin",
		home + "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS",
	}, string(os.PathListSeparator)))
	_, err := exec.LookPath("amp")
	cfg.amp = err == nil

	if *asJSON && *once {
		if err := runOnce(cfg, *cmdJSON); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if *asJSON {
		if err := runStream(cfg); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	m := newModel(cfg)
	if *once {
		ctx := context.Background()
		m.rex, m.rexErr = fetchRex(ctx, discoverHosts(ctx))
		if cfg.amp {
			m.usage, m.usageErr = fetchUsage(ctx)
			m.threads, m.threadsErr = fetchThreads(ctx, 15)
			m.remote, m.remoteErr = fetchBridge(ctx)
		}
		m.subs = fetchSubs(ctx)
		m.desktop, m.desktopErr = fetchDesktop(ctx)
		m.width, m.height = 80, 60
		fmt.Println(m.View())
		return
	}
	if _, err := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion()).Run(); err != nil {
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
	subsMsg   []SubUsage
	bridgeMsg struct {
		ts  []RemoteThread
		err error
	}
	desktopMsg struct {
		ss  []DesktopSession
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
	subs       []SubUsage
	threads    []Thread
	threadsErr error
	remote     []RemoteThread
	remoteErr  error
	desktop    []DesktopSession
	desktopErr error

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
	agentLines  map[int]int     // agents box body line -> agent index, set by View
	agentAt     map[int]int     // screen line -> agent index, set by View
	lastClick   time.Time
	lastClickAt int        // agent index of lastClick
	buttons     []buttonAt // set by View
	buttonY     int        // screen line of the buttons, set by View
}

// buttonAt is where View drew a button: columns x0 to x1 of line buttonY.
type buttonAt struct {
	x0, x1 int
	action string
}

type actionMsg struct{ err error }

// runAction runs one of init.lua's actions, which asks in the Rex app's
// command palette, and waits for it to be answered.
func (m *model) runAction(name string) tea.Cmd {
	args := []string{"do", name}
	if m.cfg.client != "" {
		args = append([]string{"-C", m.cfg.client}, args...)
	}
	m.status = "Answer in the Rex command palette…"
	return func() tea.Msg {
		_, err := run(m.ctx, 15*time.Minute, "rex", args...)
		return actionMsg{err}
	}
}

func newModel(cfg config) *model {
	return &model{cfg: cfg, ctx: context.Background(), changed: make(chan struct{}, 1)}
}

func (m *model) Init() tea.Cmd {
	m.rexLoading = true
	return tea.Batch(m.loadRex(), m.loadUsage(), m.loadThreads(), m.loadBridge(), m.loadDesktop(), m.waitChange(), tick())
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

// loadUsage checks Amp's credits and the Claude and Codex subscriptions.
func (m *model) loadUsage() tea.Cmd {
	m.lastUsage = time.Now()
	subs := func() tea.Msg { return subsMsg(fetchSubs(m.ctx)) }
	if !m.cfg.amp {
		return subs
	}
	return tea.Batch(subs, func() tea.Msg { u, err := fetchUsage(m.ctx); return usageMsg{u, err} })
}

func (m *model) loadDesktop() tea.Cmd {
	return func() tea.Msg { ss, err := fetchDesktop(m.ctx); return desktopMsg{ss, err} }
}

// alertDesktop notifies when a desktop app session finishes or needs you.
func (m *model) alertDesktop(cur []DesktopSession) {
	if m.desktop == nil {
		return
	}
	prev := map[string]string{}
	for _, s := range m.desktop {
		prev[s.ID] = s.State
	}
	for _, s := range cur {
		was, ok := prev[s.ID]
		if !ok || was == s.State {
			continue
		}
		switch {
		case s.State == "blocked":
			m.notify(appName(s.App)+" needs you", s.Task, "")
		case s.State == "done" && was == "working":
			m.notify(appName(s.App)+" finished", s.Task, "")
		}
	}
}

func (m *model) loadBridge() tea.Cmd {
	if !m.cfg.amp {
		return nil
	}
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
	if !m.cfg.amp {
		return nil
	}
	m.lastThreads = time.Now()
	return func() tea.Msg { ts, err := fetchThreads(m.ctx, 15); return threadsMsg{ts, err} }
}

func (m *model) agents() []Pane {
	var out []Pane
	for _, p := range m.rex.Panes {
		if p.IsAgent() {
			out = append(out, p)
		}
	}
	return out
}

// focus shows agent i's pane in the Rex app.
func (m *model) focus(i int) tea.Cmd {
	agents := m.agents()
	if i >= len(agents) {
		return nil
	}
	p := agents[i]
	m.status = "Showing " + paneName(p) + "…"
	return func() tea.Msg { return focusedMsg{focusPane(m.ctx, p, m.cfg.client)} }
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
			return m, m.focus(m.cursor)
		case "r":
			m.status = "Refreshing…"
			m.rexLoading = true
			return m, tea.Batch(m.loadRex(), m.loadUsage(), m.loadThreads(), m.loadDesktop())
		}

	case tea.MouseMsg:
		n := len(m.agents())
		switch {
		case msg.Action != tea.MouseActionPress:
		case msg.Button == tea.MouseButtonWheelDown:
			m.cursor = max(0, min(n-1, m.cursor+1))
		case msg.Button == tea.MouseButtonWheelUp:
			m.cursor = max(0, m.cursor-1)
		case msg.Button == tea.MouseButtonLeft && msg.Y == m.buttonY:
			for _, b := range m.buttons {
				if msg.X >= b.x0 && msg.X < b.x1 {
					return m, m.runAction(b.action)
				}
			}
		case msg.Button == tea.MouseButtonLeft:
			i, ok := m.agentAt[msg.Y]
			if !ok || i >= n {
				break
			}
			double := i == m.lastClickAt && time.Since(m.lastClick) < 400*time.Millisecond
			m.cursor, m.lastClickAt, m.lastClick = i, i, time.Now()
			if double {
				m.lastClick = time.Time{} // a third click starts over
				return m, m.focus(i)
			}
		}

	case actionMsg:
		m.status = ""
		if msg.err != nil {
			m.status = errText.Render(msg.err.Error())
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
			keepSince(m.rex, msg.snap)
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

	case subsMsg:
		if m.status == "Refreshing…" && !m.cfg.amp {
			m.status = ""
		}
		// Keep the last numbers a failed check had, next to its error.
		prev := map[string]SubUsage{}
		for _, s := range m.subs {
			prev[s.Name] = s
		}
		m.subs = msg
		for i, s := range m.subs {
			if s.Err != nil && s.Windows == nil {
				m.subs[i].Windows = prev[s.Name].Windows
			}
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

	case desktopMsg:
		m.desktopErr = msg.err
		if msg.err == nil || msg.ss != nil {
			m.alertDesktop(msg.ss)
			m.desktop = msg.ss
			if m.desktop == nil {
				m.desktop = []DesktopSession{}
			}
		}

	case tickMsg:
		cmds := []tea.Cmd{tick(), m.loadBridge(), m.loadDesktop()}
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

// keepSince dates the state of agents that report none, such as fm, from
// the snapshot it first appeared in.
func keepSince(old, cur RexSnapshot) {
	prev := map[string]Pane{}
	for _, p := range old.Panes {
		prev[p.BlockID] = p
	}
	for i, p := range cur.Panes {
		if p.Agent != "fm" {
			continue
		}
		if o, ok := prev[p.BlockID]; ok && o.Agent == p.Agent && o.State == p.State {
			cur.Panes[i].Since = o.Since // zero when it was already so at the start
		} else if !old.At.IsZero() {
			cur.Panes[i].Since = cur.At
		}
	}
}

// alertTransitions notifies when an agent in a pane finishes or starts waiting on you.
func (m *model) alertTransitions(old, cur RexSnapshot) {
	if old.At.IsZero() {
		return // first snapshot: nothing changed yet
	}
	prev := map[string]string{}
	for _, p := range old.Panes {
		prev[p.BlockID] = p.State
	}
	for _, p := range cur.Panes {
		if !p.IsAgent() || p.State == prev[p.BlockID] {
			continue
		}
		name := agentName(p.Agent)
		switch p.State {
		case "done":
			m.notify(name+" finished", paneName(p), p.Msg)
		case "blocked":
			m.notify(name+" needs you", paneName(p), firstNonEmpty(p.Msg, p.Kind))
		case "error":
			m.notify(name+" failed", paneName(p), p.Msg)
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
	if !m.cfg.stream {
		fmt.Fprintf(os.Stdout, "\x1b]7501;state=done:app=rex-hud:msg=%s\x1b\\", base64.StdEncoding.EncodeToString([]byte(text)))
	}
	if !m.cfg.notify || notchAppRunning() {
		return
	}
	script := fmt.Sprintf("display notification %q with title %q subtitle %q", body, title, subtitle)
	_ = exec.Command("osascript", "-e", script).Start()
}

// notchAppRunning reports whether RexNotch is up. It posts the same alerts
// with its own icon and buttons, whereas osascript's carry no icon.
func notchAppRunning() bool {
	if runtime.GOOS != "darwin" {
		return false
	}
	return exec.Command("pgrep", "-x", "RexNotch").Run() == nil
}

func firstNonEmpty(s ...string) string {
	for _, v := range s {
		if v != "" {
			return v
		}
	}
	return ""
}
