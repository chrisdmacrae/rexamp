package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
)

var (
	accent  = lipgloss.Color("#7C6CFF")
	dim     = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
	bold    = lipgloss.NewStyle().Bold(true)
	errText = lipgloss.NewStyle().Foreground(lipgloss.Color("203"))
	heading = lipgloss.NewStyle().Bold(true).Foreground(accent)
	panel   = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(lipgloss.Color("238")).Padding(0, 1)
	sel     = lipgloss.NewStyle().Background(lipgloss.Color("236"))
	button  = lipgloss.NewStyle().Background(accent).Foreground(lipgloss.Color("#FFFFFF")).Bold(true).Padding(0, 1)

	stateStyle = map[string]lipgloss.Style{
		"working": lipgloss.NewStyle().Foreground(lipgloss.Color("39")),
		"done":    lipgloss.NewStyle().Foreground(lipgloss.Color("42")),
		"blocked": lipgloss.NewStyle().Foreground(lipgloss.Color("214")).Bold(true),
		"error":   lipgloss.NewStyle().Foreground(lipgloss.Color("203")).Bold(true),
		"idle":    dim,
		"runner":  dim,
	}
	stateIcon = map[string]string{"working": "●", "done": "✓", "blocked": "◆", "error": "✗", "idle": "○", "runner": "◇", "": "·"}
)

func (m *model) View() string {
	w := m.width
	if w <= 0 {
		w = 80
	}
	inner := w - 4 // border and padding
	if inner < 20 {
		inner = 20
	}
	box := func(title, body string) string {
		return panel.Width(inner + 2).Render(heading.Render(title) + "\n" + body)
	}

	var parts []string
	if body := m.viewUsage(inner); body != "" {
		parts = append(parts, box("Usage", body))
	}
	// The agents box's body starts after the boxes above it, its top
	// border, and its heading.
	top := lipgloss.Height(strings.Join(parts, "\n")) + 2
	if len(parts) == 0 {
		top = 2
	}
	outside := m.viewDesktop(inner)
	if m.cfg.amp {
		outside += m.viewRemote(inner)
	}
	parts = append(parts,
		box(fmt.Sprintf("Agents in Rex (%d)", len(m.agents())), m.viewAgents(inner)),
		box("Agents outside Rex", firstNonEmpty(strings.TrimSuffix(outside, "\n"), dim.Render("No agents outside Rex."))),
	)
	if m.cfg.amp {
		parts = append(parts, box("Threads", m.viewThreads(inner)))
	}
	parts = append(parts, box(fmt.Sprintf("Rex hosts (%d)", len(m.rex.Hosts)), m.viewSessions(inner)))
	help := dim.Render("j/k or click select · enter or double-click show pane · r refresh · q quit")
	if m.status != "" {
		help = m.status
	}
	// The buttons run init.lua's actions, which ask in the Rex app.
	m.buttons = m.buttons[:0]
	bar, x := "", 0
	for _, b := range []struct{ label, action string }{{"Switch to agent ⇧⌘A", "amp_agents"}, {"Reply to agent ⇧⌘R", "amp_reply"}} {
		r := button.Render(b.label)
		m.buttons = append(m.buttons, buttonAt{x, x + lipgloss.Width(r), b.action})
		bar += r + " "
		x += lipgloss.Width(r) + 1
	}
	out := strings.Join(parts, "\n") + "\n" + bar + " " + truncate(help, max(0, w-x-1))

	// Map screen lines to agents and buttons for mouse clicks. A view taller
	// than the terminal loses its top lines.
	m.buttonY = lipgloss.Height(out) - 1
	if over := lipgloss.Height(out) - m.height; m.height > 0 && over > 0 {
		top -= over
		m.buttonY -= over
	}
	m.agentAt = map[int]int{}
	for line, i := range m.agentLines {
		m.agentAt[top+line] = i
	}
	return out
}

// viewUsage shows Amp's credits when amp is installed, then the limits of
// each Claude and ChatGPT subscription with a login. It is empty when there
// is none of them.
func (m *model) viewUsage(w int) string {
	var parts []string
	if m.cfg.amp {
		parts = append(parts, m.viewCredits(w))
	}
	for _, s := range m.subs {
		parts = append(parts, viewSub(s, w))
	}
	return strings.Join(parts, "\n")
}

// viewSub shows a subscription's rate limit windows, one per line.
func viewSub(s SubUsage, w int) string {
	var b strings.Builder
	name := s.Name
	if s.Plan != "" {
		name += " · " + strings.ToUpper(s.Plan[:1]) + s.Plan[1:]
	}
	b.WriteString(bold.Render(name))
	for _, l := range s.Windows {
		style := lipgloss.NewStyle()
		switch {
		case l.Percent >= 90:
			style = errText
		case l.Percent >= 75:
			style = stateStyle["blocked"]
		}
		resets := ""
		if !l.ResetsAt.IsZero() {
			resets = "resets in " + until(l.ResetsAt)
		}
		fmt.Fprintf(&b, "\n  %-13s %s %s  %s", l.Label, style.Render(meter(l.Percent, 10)), style.Render(fmt.Sprintf("%3.0f%%", l.Percent)), dim.Render(resets))
	}
	if s.Err != nil {
		b.WriteString("\n" + errText.Render(truncate("  "+s.Err.Error(), w)))
	} else if len(s.Windows) == 0 {
		b.WriteString("\n" + dim.Render("  no limits reported"))
	}
	return b.String()
}

// meter draws percent of width cells as a bar.
func meter(percent float64, width int) string {
	n := int(percent/100*float64(width) + 0.5)
	n = max(0, min(width, n))
	return strings.Repeat("█", n) + strings.Repeat("░", width-n)
}

// until is how long until t, such as "4h12m" or "2d5h".
func until(t time.Time) string {
	d := time.Until(t).Round(time.Minute)
	switch {
	case d <= 0:
		return "now"
	case d >= 24*time.Hour:
		return fmt.Sprintf("%dd%dh", int(d.Hours())/24, int(d.Hours())%24)
	case d >= time.Hour:
		return fmt.Sprintf("%dh%02dm", int(d.Hours()), int(d.Minutes())%60)
	}
	return fmt.Sprintf("%dm", int(d.Minutes()))
}

func (m *model) viewCredits(w int) string {
	if m.usage.FetchedAt.IsZero() {
		if m.usageErr != nil {
			return bold.Render("Amp") + "\n" + errText.Render(truncate(m.usageErr.Error(), w))
		}
		return bold.Render("Amp") + "\n" + dim.Render("Loading `amp usage`…")
	}
	u := m.usage
	var b strings.Builder
	credits := "Amp · " + firstNonEmpty(u.Credits, "credits unknown")
	if m.cfg.lowCredits > 0 && u.CreditsUSD >= 0 && u.CreditsUSD < m.cfg.lowCredits {
		credits = errText.Render(credits + "  LOW")
	} else {
		credits = bold.Render(credits)
	}
	fmt.Fprintln(&b, credits)
	fmt.Fprintf(&b, "7 days: %s tokens · %s\n", firstNonEmpty(u.TotalTokens, "?"), firstNonEmpty(u.TotalCost, "?"))

	if days := u.Tables["Daily Recorded Cost"]; len(days) > 0 {
		var vals []float64
		for _, r := range days {
			if len(r) > 0 {
				vals = append(vals, parseNumber(r[len(r)-1]))
			}
		}
		today := days[len(days)-1]
		fmt.Fprintf(&b, "Daily cost %s  today %s\n", sparkline(vals), today[len(today)-1])
	}
	for _, r := range u.Tables["Models"] {
		if len(r) >= 7 {
			fmt.Fprintln(&b, truncate(fmt.Sprintf("  %-16s %10s tok  %s", r[0], r[5], r[6]), w))
		}
	}
	for _, r := range u.Tables["From"] {
		if len(r) >= 3 {
			fmt.Fprintln(&b, dim.Render(truncate(fmt.Sprintf("  via %s: %s tok, %s", r[0], r[1], r[2]), w)))
		}
	}
	age := dim.Render("updated " + ago(u.FetchedAt))
	if m.usageErr != nil {
		age = errText.Render(truncate("refresh failed: "+m.usageErr.Error(), w))
	}
	b.WriteString(age)
	return b.String()
}

// viewAgents lists agents one per line under a "host › session" heading: what
// each is doing, then its directory, state, and how long it has been in it.
// The selected agent also gets a line with its tab, pane, and ports.
func (m *model) viewAgents(w int) string {
	if m.rex.At.IsZero() {
		if m.rexErr != nil {
			return errText.Render(truncate(m.rexErr.Error(), w))
		}
		return dim.Render("Reading Rex…")
	}
	agents := m.agents()
	if len(agents) == 0 {
		return dim.Render("No panes are running an agent.")
	}
	// Line the directory and state columns up across rows.
	var dirW, stateW int
	for _, p := range agents {
		dirW = max(dirW, min(16, lipgloss.Width(shortPath(p.Cwd))))
		stateW = max(stateW, lipgloss.Width(paneStateText(p)))
	}
	lines := []string{agentSummary(agents)}
	m.agentLines = map[int]int{}
	group := ""
	for i, p := range agents {
		if g := shortHost(p.Host) + " › " + p.SessionLabel; g != group {
			group = g
			lines = append(lines, bold.Render(truncate(g, w)))
		}
		m.agentLines[len(lines)] = i
		lines = append(lines, m.agentRow(p, i == m.cursor, w, dirW, stateW))
		if i == m.cursor {
			if d := paneDetail(p); d != "" {
				m.agentLines[len(lines)] = i
				lines = append(lines, dim.Render(truncate("      "+d, w)))
			}
		}
	}
	return strings.Join(lines, "\n")
}

// agentSummary counts agents by state, most urgent first.
func agentSummary(agents []Pane) string {
	count := map[string]int{}
	for _, p := range agents {
		count[paneState(p)]++
	}
	var parts []string
	for _, s := range []string{"blocked", "error", "working", "done", "idle", "runner"} {
		if n := count[s]; n > 0 {
			label := s
			switch {
			case s == "blocked":
				label = "need you"
			case s == "runner" && n > 1:
				label = "runners"
			}
			parts = append(parts, stateStyle[s].Render(fmt.Sprintf("%s %d %s", stateIcon[s], n, label)))
		}
	}
	return strings.Join(parts, dim.Render(" · "))
}

func (m *model) agentRow(p Pane, selected bool, w, dirW, stateW int) string {
	state := paneState(p)
	st := stateStyle[state]
	cursor := "  "
	if selected {
		cursor = lipgloss.NewStyle().Foreground(accent).Render("▌ ")
	}
	left := cursor + st.Render(stateIcon[state]) + " " + fmt.Sprintf("%-6s ", p.Agent)

	stateText := paneStateText(p)
	right := dim.Render(fmt.Sprintf("%-*s", dirW, truncate(shortPath(p.Cwd), dirW))) + "  " +
		st.Render(fmt.Sprintf("%-*s", stateW, stateText))

	task := m.paneTask(p)
	switch {
	case state == "blocked":
		why := map[string]string{"permission": "needs permission", "question": "has a question", "auth": "needs login"}[p.Kind]
		why = firstNonEmpty(why, "needs you")
		if p.Msg != "" {
			why += ": " + p.Msg
		}
		task += st.Render(" · " + why)
	case state == "error" && p.Msg != "":
		task += st.Render(" · " + p.Msg)
	case state == "working" && p.Msg != "" && p.Msg != task:
		task += dim.Render(" · " + p.Msg)
	}
	if selected {
		task = bold.Render(task)
	}
	room := w - lipgloss.Width(left) - lipgloss.Width(right) - 2
	task = truncate(task, max(8, room))
	pad := w - lipgloss.Width(left) - lipgloss.Width(task) - lipgloss.Width(right)
	return left + task + strings.Repeat(" ", max(1, pad)) + right
}

// paneStateText is the state column: the state and how long ago it began.
func paneStateText(p Pane) string {
	state := paneState(p)
	if state == "runner" {
		return ""
	}
	if state == "blocked" {
		state = "needs you"
	}
	if !p.Since.IsZero() {
		return state + " " + ago(p.Since)
	}
	return state
}

// paneState is the state to show: an Amp runner hosts threads rather than
// working itself, and an agent that reports nothing is idle.
func paneState(p Pane) string {
	if p.State == "" && isAmpRunner(p) {
		return "runner"
	}
	return firstNonEmpty(p.State, "idle")
}

func isAmpRunner(p Pane) bool { return strings.Contains(p.Title, " - amp runner") }

// paneDetail names the pane's tab and pane when they have been given labels,
// and lists the ports its agent listens on.
func paneDetail(p Pane) string {
	var parts []string
	if p.WindowLabel != "" && !defaultWindowRe.MatchString(p.WindowLabel) {
		parts = append(parts, "tab "+p.WindowLabel)
	}
	if p.Label != "" && p.Label != "shell" {
		parts = append(parts, "pane "+p.Label)
	}
	if p.Cwd != "" {
		parts = append(parts, strings.Replace(p.Cwd, homeDir, "~", 1))
	}
	if len(p.Ports) > 0 {
		parts = append(parts, fmt.Sprintf("ports %v", p.Ports))
	}
	return strings.Join(parts, " · ")
}

// shortHost drops the domain from a host label such as
// "mac-mini.tail1234.ts.net".
func shortHost(h string) string {
	name, _, _ := strings.Cut(h, ".")
	return name
}

// viewRemote shows threads running on orbs, other runners, or Amp's web and
// editor clients, as the amp-hud-bridge plugin reports them.
func (m *model) viewRemote(w int) string {
	if m.remote == nil {
		if m.remoteErr != nil {
			return dim.Render(truncate(m.remoteErr.Error(), w))
		}
		return dim.Render("Asking the bridge plugin…")
	}
	var lines []string
	offline := 0
	for _, t := range m.remoteAgents() {
		st := hudState(t.State)
		if st == "" {
			offline++
			continue
		}
		where := shortPath(strings.TrimPrefix(t.Tree, "file://"))
		line := fmt.Sprintf("%s %-7s %s", stateIcon[st], st, firstNonEmpty(t.Title, t.ID))
		lines = append(lines, stateStyle[st].Render(truncate(line, w-len(where)-1))+" "+dim.Render(where))
	}
	if len(lines) == 0 {
		lines = append(lines, dim.Render("No live threads outside Rex panes."))
	}
	if offline > 0 {
		lines = append(lines, dim.Render(fmt.Sprintf("%d recent threads offline", offline)))
	}
	if m.remoteErr != nil {
		lines = append(lines, errText.Render(truncate("refresh failed: "+m.remoteErr.Error(), w)))
	}
	return strings.Join(lines, "\n")
}

// viewDesktop lists the sessions of the Claude and ChatGPT desktop apps, one
// per line, above the bridge's threads.
func (m *model) viewDesktop(w int) string {
	var lines []string
	for _, s := range m.desktop {
		st := s.State
		label := st
		if st == "blocked" {
			label = "needs you"
		}
		meta := appName(s.App) + "  " + truncate(shortPath(s.Cwd), 16)
		left := truncate(fmt.Sprintf("%s %-12s %s", stateIcon[st], label+" "+ago(s.Since), s.Task), max(8, w-lipgloss.Width(meta)-1))
		pad := w - lipgloss.Width(left) - lipgloss.Width(meta)
		lines = append(lines, stateStyle[st].Render(left)+strings.Repeat(" ", max(1, pad))+dim.Render(meta))
	}
	if m.desktopErr != nil {
		lines = append(lines, errText.Render(truncate("desktop apps: "+m.desktopErr.Error(), w)))
	}
	if len(lines) == 0 {
		return ""
	}
	return strings.Join(lines, "\n") + "\n"
}

func (m *model) viewThreads(w int) string {
	if m.threads == nil {
		if m.threadsErr != nil {
			return errText.Render(truncate(m.threadsErr.Error(), w))
		}
		return dim.Render("Loading threads…")
	}
	tokens := map[string]string{}
	for _, r := range m.usage.Tables["Top Threads by Tokens"] {
		if id := threadIDRe.FindString(r[0]); id != "" && len(r) > 1 {
			tokens[id] = r[1]
		}
	}
	var lines []string
	limit := 6
	if m.height > 0 {
		limit = max(3, min(10, (m.height-30)))
	}
	for i, t := range m.threads {
		if i >= limit {
			break
		}
		meta := fmt.Sprintf("%dmsg", t.MessageCount)
		if tok := tokens[t.ID]; tok != "" {
			meta += " " + tok + "tok"
		}
		meta += " " + ago(t.Updated)
		title := truncate(firstNonEmpty(t.Title, t.ID), max(8, w-len(meta)-1))
		pad := w - lipgloss.Width(title) - len(meta)
		lines = append(lines, title+strings.Repeat(" ", max(1, pad))+dim.Render(meta))
	}
	return strings.Join(lines, "\n")
}

func (m *model) viewSessions(w int) string {
	if len(m.rex.Hosts) == 0 {
		return dim.Render("Finding Rex hosts…")
	}
	var lines []string
	for _, h := range m.rex.Hosts {
		if h.Err != nil {
			lines = append(lines, errText.Render(truncate(h.Label+"  unreachable: "+h.Err.Error(), w)))
			continue
		}
		lines = append(lines, bold.Render(h.Label))
		n := 0
		for _, s := range m.rex.Sessions {
			if s.Host == h.Label {
				n++
				lines = append(lines, truncate(fmt.Sprintf("  %-18s %d tabs · %d panes · %d agents", s.Label, s.Windows, s.Panes, s.Agents), w))
			}
		}
		if n == 0 {
			lines = append(lines, dim.Render("  no sessions"))
		}
	}
	return strings.Join(lines, "\n")
}

var (
	threadIDRe = regexp.MustCompile(`T-[0-9a-f-]{36}`)
	// Agents show progress at the start of the title: a braille spinner, or
	// "[ ! ] Action Required | " while Codex waits for approval.
	spinnerRe = regexp.MustCompile(`^(?:[\x{2800}-\x{28FF}]\s*|\[ ! \] Action Required \| )`)
	// Rex names a window "Window" and the start of its ID until it is labeled.
	defaultWindowRe = regexp.MustCompile(`^Window [0-9a-f]{8}$`)
	runnerThreadsRe = regexp.MustCompile(`\((\d+ threads?)\)`)
	homeDir, _      = os.UserHomeDir()
)

// threadTitleFor finds the Amp thread a pane is showing. Amp puts the thread
// title at the start of the terminal title: "<thread> - amp - <dir>".
func (m *model) threadTitleFor(p Pane) string {
	t := spinnerRe.ReplaceAllString(p.Title, "")
	name, _, ok := strings.Cut(t, " - amp")
	if !ok || name == "" || name == "amp" || isAmpRunner(p) {
		return ""
	}
	return name
}

// paneTask is what the pane's agent is working on. Claude Code and Codex put
// their task in the terminal title, Codex followed by " | <dir>", which the
// row shows anyway.
func (m *model) paneTask(p Pane) string {
	if isAmpRunner(p) {
		if n := runnerThreadsRe.FindStringSubmatch(p.Title); n != nil {
			return "runner for " + n[1]
		}
		return "runner"
	}
	if p.Agent == "amp" {
		return firstNonEmpty(m.threadTitleFor(p), "new thread")
	}
	if p.Task != "" {
		return p.Task
	}
	t := spinnerRe.ReplaceAllString(p.Title, "")
	if dir := shortPath(p.Cwd); dir != "" {
		t = strings.TrimSuffix(t, " | "+dir)
	}
	return firstNonEmpty(t, "new session")
}

func agentName(agent string) string {
	switch agent {
	case "claude":
		return "Claude Code"
	case "codex":
		return "Codex"
	case "fm":
		return "Foundation Models"
	}
	return "Amp"
}

func paneName(p Pane) string {
	return shortHost(p.Host) + " › " + p.SessionLabel + " › " + firstNonEmpty(p.WindowLabel, "tab") + " › " + firstNonEmpty(p.Label, shortPath(p.Cwd))
}

func shortPath(p string) string {
	if p == "" {
		return ""
	}
	return filepath.Base(p)
}

func sparkline(vals []float64) string {
	bars := []rune("▁▂▃▄▅▆▇█")
	hi := 0.0
	for _, v := range vals {
		hi = max(hi, v)
	}
	var b strings.Builder
	for _, v := range vals {
		i := 0
		if hi > 0 {
			i = int(v / hi * float64(len(bars)-1))
		}
		b.WriteRune(bars[i])
	}
	return b.String()
}

func ago(t time.Time) string {
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return "now"
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	}
	return fmt.Sprintf("%dd", int(d.Hours()/24))
}

func truncate(s string, w int) string {
	if lipgloss.Width(s) <= w {
		return s
	}
	r := []rune(s)
	for len(r) > 0 && lipgloss.Width(string(r))+1 > w {
		r = r[:len(r)-1]
	}
	return string(r) + "…"
}
