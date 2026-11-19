package main

import (
	"fmt"
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

	stateStyle = map[string]lipgloss.Style{
		"working": lipgloss.NewStyle().Foreground(lipgloss.Color("39")),
		"done":    lipgloss.NewStyle().Foreground(lipgloss.Color("42")),
		"blocked": lipgloss.NewStyle().Foreground(lipgloss.Color("214")).Bold(true),
		"error":   lipgloss.NewStyle().Foreground(lipgloss.Color("203")).Bold(true),
		"idle":    dim,
	}
	stateIcon = map[string]string{"working": "●", "done": "✓", "blocked": "◆", "error": "✗", "idle": "○", "": "·"}
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

	parts := []string{
		box("Amp credits", m.viewCredits(inner)),
		box(fmt.Sprintf("Agents in Rex (%d)", len(m.agents())), m.viewAgents(inner)),
		box("Agents outside Rex", m.viewRemote(inner)),
		box("Threads", m.viewThreads(inner)),
		box(fmt.Sprintf("Rex hosts (%d)", len(m.rex.Hosts)), m.viewSessions(inner)),
	}
	help := dim.Render("j/k select · enter show pane · r refresh · q quit")
	if m.status != "" {
		help = m.status
	}
	return strings.Join(parts, "\n") + "\n" + truncate(help, w)
}

func (m *model) viewCredits(w int) string {
	if m.usage.FetchedAt.IsZero() {
		if m.usageErr != nil {
			return errText.Render(truncate(m.usageErr.Error(), w))
		}
		return dim.Render("Loading `amp usage`…")
	}
	u := m.usage
	var b strings.Builder
	credits := firstNonEmpty(u.Credits, "credits unknown")
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

func (m *model) viewAgents(w int) string {
	if m.rex.At.IsZero() {
		if m.rexErr != nil {
			return errText.Render(truncate(m.rexErr.Error(), w))
		}
		return dim.Render("Reading Rex…")
	}
	agents := m.agents()
	if len(agents) == 0 {
		return dim.Render("No panes are running amp.")
	}
	var lines []string
	for i, p := range agents {
		st := stateStyle[p.State]
		head := fmt.Sprintf("%s %-7s %s", stateIcon[p.State], firstNonEmpty(p.State, "-"), paneName(p))
		line := st.Render(truncate(head, w))
		detail := firstNonEmpty(p.Msg, m.threadTitleFor(p), shortPath(p.Cwd))
		if p.State == "blocked" && p.Kind != "" {
			detail = p.Kind + ": " + detail
		}
		if len(p.Ports) > 0 {
			detail += fmt.Sprintf("  ports %v", p.Ports)
		}
		line += "\n" + dim.Render(truncate("    "+detail, w))
		if i == m.cursor {
			line = sel.Width(w).Render(line)
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n")
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
				lines = append(lines, truncate(fmt.Sprintf("  %-18s %d tabs · %d panes · %d amp", s.Label, s.Windows, s.Panes, s.Agents), w))
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
	spinnerRe  = regexp.MustCompile(`^[\x{2800}-\x{28FF}]\s*`)
)

// threadTitleFor finds the Amp thread a pane is showing. Amp puts the thread
// title at the start of the terminal title: "<thread> - amp - <dir>".
func (m *model) threadTitleFor(p Pane) string {
	t := spinnerRe.ReplaceAllString(p.Title, "")
	name, _, ok := strings.Cut(t, " - amp")
	if !ok || name == "" || name == "amp" {
		return ""
	}
	return name
}

func paneName(p Pane) string {
	return p.Host + " › " + p.SessionLabel + " › " + firstNonEmpty(p.WindowLabel, "tab") + " › " + firstNonEmpty(p.Label, shortPath(p.Cwd))
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
