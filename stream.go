package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"regexp"
	"strings"
	"time"
	"unicode"

	tea "github.com/charmbracelet/bubbletea"
)

// The -json mode runs the HUD without a screen for other front ends, such as
// the notch app in notch/. It writes a snapshot as one JSON line on stdout
// whenever what it shows changes, and reads commands as JSON lines on stdin:
//
//	{"op":"focus","block":"block:…"}         show the pane in the Rex app
//	{"op":"choose","block":"block:…","option":1} pick a choice of its prompt, from 0
//	{"op":"reply","block":"block:…","text":"…"}  type an answer and press Return
//	{"op":"refresh"}                         reload everything now
//
// With -once, it writes one snapshot of the Rex agents and exits, or runs the
// command given with -cmd. See runOnce.

type streamAgent struct {
	Block   string    `json:"block"`
	Host    string    `json:"host"`
	Session string    `json:"session"`
	Window  string    `json:"window"`
	Agent   string    `json:"agent"` // amp, claude, or codex
	Name    string    `json:"name"`  // Amp, Claude Code, or Codex
	Task    string    `json:"task"`
	Cwd     string    `json:"cwd"`
	State   string    `json:"state"` // idle, working, done, blocked, error
	Kind    string    `json:"kind,omitempty"`
	Msg     string    `json:"msg,omitempty"`
	Since   time.Time `json:"since,omitzero"`
	Ports   []int     `json:"ports,omitempty"`
	Prompt  *Prompt   `json:"prompt,omitempty"`
	// Question is what a finished agent asked at the end of its turn.
	Question string `json:"question,omitempty"`
}

type streamRemote struct {
	ID      string    `json:"id"`
	Title   string    `json:"title"`
	State   string    `json:"state"`
	Updated time.Time `json:"updated"`
}

type streamDesktop struct {
	ID     string    `json:"id"`
	App    string    `json:"app"`    // claude or chatgpt
	Name   string    `json:"name"`   // Claude or ChatGPT
	Bundle string    `json:"bundle"` // the app's bundle ID, to open it
	Task   string    `json:"task"`
	Cwd    string    `json:"cwd"`
	State  string    `json:"state"`
	Kind   string    `json:"kind,omitempty"`
	Since  time.Time `json:"since,omitzero"`
}

type streamUsage struct {
	Credits    string  `json:"credits"`
	CreditsUSD float64 `json:"credits_usd"`
	WeekCost   string  `json:"week_cost,omitempty"`
	TodayCost  string  `json:"today_cost,omitempty"`
	Low        bool    `json:"low"`
}

type streamSub struct {
	Name    string         `json:"name"` // Claude Code or Codex
	Plan    string         `json:"plan,omitempty"`
	Windows []streamWindow `json:"windows"`
	Error   string         `json:"error,omitempty"`
}

type streamWindow struct {
	Label    string    `json:"label"` // 5-hour, weekly, weekly Opus…
	Percent  float64   `json:"percent"`
	ResetsAt time.Time `json:"resets_at,omitzero"`
}

type streamSnapshot struct {
	Type    string            `json:"type"` // "snapshot"
	Agents  []streamAgent     `json:"agents"`
	Remote  []streamRemote    `json:"remote"`
	Desktop []streamDesktop   `json:"desktop"`
	Usage   *streamUsage      `json:"usage,omitempty"` // Amp, only when amp is installed
	Subs    []streamSub       `json:"subscriptions"`
	Errors  map[string]string `json:"errors,omitempty"`
}

type commandMsg struct {
	Op     string `json:"op"`
	Block  string `json:"block"`
	Option int    `json:"option"`
	Text   string `json:"text"`
}

type statusMsg string

type streamModel struct {
	*model
	last []byte
}

func runStream(cfg config) error {
	cfg.stream = true
	s := &streamModel{model: newModel(cfg)}
	p := tea.NewProgram(s, tea.WithoutRenderer(), tea.WithInput(nil), tea.WithOutput(io.Discard))
	go func() {
		sc := bufio.NewScanner(os.Stdin)
		for sc.Scan() {
			var c commandMsg
			if json.Unmarshal(sc.Bytes(), &c) == nil {
				p.Send(c)
			}
		}
		p.Quit() // the front end went away
	}()
	_, err := p.Run()
	return err
}

// runOnce is -json with -once, for the Rex actions in init.lua. It reads the
// Rex panes once and writes one snapshot or, given cmd, runs that command on
// them. It skips usage, threads, and desktop apps, so running it on every key
// press is quick and spends none of Amp's usage lookups.
func runOnce(cfg config, cmd string) error {
	cfg.stream = true
	s := &streamModel{model: newModel(cfg)}
	ctx := context.Background()
	s.rex, s.rexErr = fetchRex(ctx, discoverHosts(ctx))
	if cmd == "" {
		writeLine(s.snapshot())
		return nil
	}
	var c commandMsg
	if err := json.Unmarshal([]byte(cmd), &c); err != nil {
		return err
	}
	if c.Op == "refresh" {
		return errors.New("refresh only works in the -json stream")
	}
	if s.rexErr != nil {
		return s.rexErr
	}
	if f := s.command(c); f != nil {
		if msg, ok := f().(statusMsg); ok {
			return errors.New(string(msg))
		}
	}
	return nil
}

func (s *streamModel) View() string { return "" }

func (s *streamModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd
	switch msg := msg.(type) {
	case tea.KeyMsg, tea.MouseMsg, tea.WindowSizeMsg:
		return s, nil
	case commandMsg:
		cmd = s.command(msg)
	case statusMsg:
		writeLine(map[string]string{"type": "status", "message": string(msg)})
		return s, nil
	default:
		_, cmd = s.model.Update(msg)
	}
	if b, _ := json.Marshal(s.snapshot()); !bytes.Equal(b, s.last) {
		s.last = b
		os.Stdout.Write(append(b, '\n'))
	}
	return s, cmd
}

func (s *streamModel) command(c commandMsg) tea.Cmd {
	if c.Op == "refresh" {
		s.rexLoading = true
		return tea.Batch(s.loadRex(), s.loadUsage(), s.loadThreads(), s.loadBridge(), s.loadDesktop())
	}
	var pane *Pane
	for _, p := range s.agents() {
		if p.BlockID == c.Block {
			pane = &p
		}
	}
	if pane == nil {
		return func() tea.Msg { return statusMsg("That pane is gone.") }
	}
	p := *pane
	switch c.Op {
	case "focus":
		return func() tea.Msg {
			if err := focusPane(s.ctx, p, s.cfg.client); err != nil {
				return statusMsg("Couldn't switch the Rex app to the pane (turn on Remote Control): " + err.Error())
			}
			return nil
		}
	case "reply":
		// One line: a newline would send the answer early.
		text := strings.TrimSpace(strings.NewReplacer("\r\n", " ", "\n", " ", "\r", " ").Replace(c.Text))
		if text == "" {
			return nil
		}
		return func() tea.Msg {
			for _, args := range [][]string{
				{"send", "-s", p.SessionID, "-b", p.BlockID, "--", text},
				{"send-key", "-s", p.SessionID, "-b", p.BlockID, "enter"},
			} {
				if _, err := run(s.ctx, 10*time.Second, "rex", rexArgs(p.Server, args...)...); err != nil {
					return statusMsg(err.Error())
				}
			}
			s.changed <- struct{}{} // reload Rex to see the agent pick it up
			return nil
		}
	case "choose":
		if p.Prompt == nil || c.Option < 0 || c.Option >= len(p.Prompt.Options) {
			return func() tea.Msg { return statusMsg("That prompt is gone.") }
		}
		args := append([]string{"send-key", "-s", p.SessionID, "-b", p.BlockID}, chooseKeys(p.Prompt, c.Option)...)
		return func() tea.Msg {
			if _, err := run(s.ctx, 10*time.Second, "rex", rexArgs(p.Server, args...)...); err != nil {
				return statusMsg(err.Error())
			}
			s.changed <- struct{}{} // reload Rex to see the prompt go away
			return nil
		}
	}
	return nil
}

func (s *streamModel) snapshot() streamSnapshot {
	snap := streamSnapshot{Type: "snapshot", Agents: []streamAgent{}, Remote: []streamRemote{}, Desktop: []streamDesktop{}, Subs: []streamSub{}, Errors: map[string]string{}}
	for _, p := range s.agents() {
		state := paneState(p)
		if state == "runner" {
			continue // a runner hosts threads; the bridge lists them as remote
		}
		snap.Agents = append(snap.Agents, streamAgent{
			Block: p.BlockID, Host: shortHost(p.Host), Session: p.SessionLabel, Window: p.WindowLabel,
			Agent: p.Agent, Name: agentName(p.Agent), Task: s.paneTask(p), Cwd: p.Cwd,
			State: state, Kind: p.Kind, Msg: p.Msg, Since: p.Since, Ports: p.Ports, Prompt: p.Prompt, Question: p.Question,
		})
	}
	for _, t := range s.remoteAgents() {
		if st := hudState(t.State); st != "" {
			snap.Remote = append(snap.Remote, streamRemote{ID: t.ID, Title: firstNonEmpty(t.Title, t.ID), State: st, Updated: t.Updated})
		}
	}
	for _, d := range s.desktop {
		snap.Desktop = append(snap.Desktop, streamDesktop{
			ID: d.ID, App: d.App, Name: appName(d.App), Bundle: appBundleID(d.App),
			Task: d.Task, Cwd: d.Cwd, State: d.State, Kind: d.Kind, Since: d.Since,
		})
	}
	if u := s.usage; !u.FetchedAt.IsZero() {
		su := &streamUsage{Credits: u.Credits, CreditsUSD: u.CreditsUSD, WeekCost: u.TotalCost}
		if days := u.Tables["Daily Recorded Cost"]; len(days) > 0 {
			today := days[len(days)-1]
			su.TodayCost = today[len(today)-1]
		}
		su.Low = s.cfg.lowCredits > 0 && u.CreditsUSD >= 0 && u.CreditsUSD < s.cfg.lowCredits
		snap.Usage = su
	}
	for _, sub := range s.subs {
		ss := streamSub{Name: sub.Name, Plan: sub.Plan, Windows: []streamWindow{}}
		for _, w := range sub.Windows {
			ss.Windows = append(ss.Windows, streamWindow{w.Label, w.Percent, w.ResetsAt})
		}
		if sub.Err != nil {
			ss.Error = sub.Err.Error()
		}
		snap.Subs = append(snap.Subs, ss)
	}
	for name, err := range map[string]error{"rex": s.rexErr, "usage": s.usageErr, "bridge": s.remoteErr, "desktop": s.desktopErr} {
		if err != nil {
			snap.Errors[name] = err.Error()
		}
	}
	return snap
}

func writeLine(v any) {
	b, _ := json.Marshal(v)
	os.Stdout.Write(append(b, '\n'))
}

// Prompt is what a blocked agent is asking, read from its screen: the
// question, the numbered choices of its menu with the highlighted one, and the
// other lines of the prompt, such as the diff of an edit it wants to make.
type Prompt struct {
	Question string   `json:"question"`
	Options  []Option `json:"options"`
	Selected int      `json:"selected"` // index into Options of the highlighted choice
	Preview  []string `json:"preview,omitempty"`
}

type Option struct {
	Key    string `json:"key"`
	Label  string `json:"label"`
	Detail string `json:"detail,omitempty"`
}

var (
	// "❯ 1. Yes" in Claude Code, "› 1. Yes, proceed (y)" in Codex.
	optionRe = regexp.MustCompile(`^([❯›>▶]\s*)?(\d)[.)]\s+(.+?)$`)
	hintRe   = regexp.MustCompile(`\s+\((?:esc|shift\+tab|[a-z])\)$`)
	ruleRe   = regexp.MustCompile(`^[─━═-]{8,}$`)
	dashedRe = regexp.MustCompile(`^[╌┄┈]{8,}$`)
)

// parsePrompt finds the last numbered menu on a screen, which Claude Code and
// Codex show for permissions and questions. It returns nil when there is none.
func parsePrompt(screen string) *Prompt {
	var lines []string
	for _, l := range strings.Split(screen, "\n") {
		lines = append(lines, strings.TrimSpace(strings.Trim(strings.TrimSpace(l), "│┃║")))
	}

	// Read the menu upward from its last choice to choice 1. Lines between
	// choices either describe the choice above, starting with a capital as
	// in Claude Code's questions, or continue its wrapped label, as in Codex.
	end := len(lines) - 1
	for end >= 0 && !optionRe.MatchString(lines[end]) {
		end--
	}
	if end < 0 {
		return nil
	}
	var opts []Option
	pr := &Prompt{}
	cont, detail := "", ""
	start := end
	for ; start >= 0; start-- {
		l := lines[start]
		m := optionRe.FindStringSubmatch(l)
		switch {
		case m != nil:
		case l == "":
			return nil
		case ruleRe.MatchString(l):
			continue
		case unicode.IsUpper([]rune(l)[0]):
			detail = strings.TrimSpace(l + " " + detail)
			continue
		default:
			cont = strings.TrimSpace(l + " " + cont)
			continue
		}
		label := hintRe.ReplaceAllString(strings.TrimSpace(m[3]+" "+cont), "")
		opts = append([]Option{{Key: m[2], Label: label, Detail: detail}}, opts...)
		cont, detail = "", ""
		if m[1] != "" {
			pr.Selected = -len(opts) // fixed up below, once the count is known
		}
		if m[2] == "1" {
			break
		}
	}
	if start < 0 || len(opts) < 2 {
		return nil
	}
	for i, o := range opts {
		if o.Key != string(rune('1'+i)) {
			return nil // not a menu, such as a numbered list in the output
		}
	}
	pr.Options = opts
	if pr.Selected < 0 {
		pr.Selected = len(opts) + pr.Selected
	}

	// The prompt is the text above the menu, back to a rule, a box edge, or
	// two blank lines. Its question is the first line that asks one.
	top := start
	for top > 0 && lines[top-1] == "" {
		top--
	}
	bottom := top
	for top > 0 && bottom-top < 20 {
		l := lines[top-1]
		if ruleRe.MatchString(l) || strings.HasPrefix(l, "╭") || strings.HasPrefix(l, "╰") || (l == "" && top >= 2 && lines[top-2] == "") {
			break
		}
		top--
	}
	var body []string
	for _, l := range lines[top:bottom] {
		if dashedRe.MatchString(l) || strings.HasPrefix(l, "☐") || (l == "" && (len(body) == 0 || body[len(body)-1] == "")) {
			continue
		}
		body = append(body, l)
	}
	q := -1
	for i, l := range body {
		if strings.HasSuffix(l, "?") {
			q = i
			break
		}
	}
	if q < 0 {
		q = len(body) - 1
	}
	if q >= 0 {
		pr.Question = body[q]
		body = append(body[:q], body[q+1:]...)
	}
	for len(body) > 0 && body[0] == "" {
		body = body[1:]
	}
	for len(body) > 0 && body[len(body)-1] == "" {
		body = body[:len(body)-1]
	}
	if len(body) > 0 {
		pr.Preview = body
	}
	return pr
}

// footerRe matches the status lines agents draw between their answer and
// the input box: Claude Code's "✻ Cooked for 3s" and update notice, and
// Codex's "Worked for 3s".
var footerRe = regexp.MustCompile(`^(✻ |Worked for |.*Update available)`)

// lastQuestion returns the last paragraph an agent wrote above its input
// box when it ends with a question mark, and "" otherwise. Amp draws the
// box from "╭", Claude Code puts "❯" under a rule, and Codex starts it with
// "›". It is a guess from the screen, so it can miss a question or flag a
// sentence that only ends in one.
func lastQuestion(screen string) string {
	lines := strings.Split(screen, "\n")
	for i := range lines {
		// Amp draws its scrollbar down the right edge.
		lines[i] = strings.TrimSpace(strings.TrimRight(lines[i], " █▐▕░▒▓"))
	}
	end := len(lines)
	for i := len(lines) - 1; i >= 0; i-- {
		l := lines[i]
		if strings.HasPrefix(l, "╭") || strings.HasPrefix(l, "›") || (strings.HasPrefix(l, "❯") && i > 0 && ruleRe.MatchString(lines[i-1])) {
			end = i
			break
		}
	}
	i := end - 1
	for i >= 0 && (lines[i] == "" || ruleRe.MatchString(lines[i]) || footerRe.MatchString(lines[i])) {
		i--
	}
	var para []string
	for ; i >= 0 && lines[i] != ""; i-- {
		para = append([]string{lines[i]}, para...)
	}
	if len(para) == 0 || strings.ContainsAny(para[0][:min(len(para[0]), 4)], "┃›❯") {
		return "" // the user's own message: the agent wrote nothing after it
	}
	q := strings.TrimSpace(strings.TrimLeft(strings.Join(para, " "), "⏺• "))
	if !strings.HasSuffix(q, "?") {
		return ""
	}
	return q
}

// chooseKeys are the keys that pick choice i of a menu: arrows from the
// highlighted choice, then Return. Codex ignores digit keys, so they can't
// pick it directly.
func chooseKeys(pr *Prompt, i int) []string {
	var keys []string
	for j := pr.Selected; j < i; j++ {
		keys = append(keys, "down")
	}
	for j := pr.Selected; j > i; j-- {
		keys = append(keys, "up")
	}
	return append(keys, "enter")
}
