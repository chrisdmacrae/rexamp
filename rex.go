package main

import (
	"bufio"
	"cmp"
	"context"
	"encoding/json"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const terminalCreator = "com.superlogical.terminal"

// Host is one Rex server: this machine's, or one that `rex hosts` lists.
type Host struct {
	Label  string
	Server string // value for `rex -S`; empty for this machine's server
	ID     string // Rex host_id, used to skip a host that is this machine
	Err    error  // set when the host can't be reached
}

// discoverHosts returns this machine's server first, then every other host
// that answers. A host that is this machine under another label is skipped,
// and lends its label to the local server.
func discoverHosts(ctx context.Context) []Host {
	var me struct {
		HostID string `json:"host_id"`
	}
	local := Host{Label: "local"}
	if err := rexJSON(ctx, "", &me, "whoami", "--json"); err != nil {
		local.Err = err
	}
	local.ID = me.HostID

	var list struct {
		Hosts []struct {
			Host struct {
				Label string `json:"label"`
			} `json:"host"`
		} `json:"hosts"`
	}
	_ = rexJSON(ctx, "", &list, "hosts", "--json")

	remote := make([]Host, len(list.Hosts))
	var wg sync.WaitGroup
	for i, h := range list.Hosts {
		remote[i] = Host{Label: h.Host.Label, Server: h.Host.Label}
		wg.Add(1)
		go func(h *Host) {
			defer wg.Done()
			var who struct {
				HostID string `json:"host_id"`
			}
			h.Err = rexJSON(ctx, h.Server, &who, "whoami", "--json")
			h.ID = who.HostID
		}(&remote[i])
	}
	wg.Wait()

	hosts := []Host{local}
	seen := map[string]bool{local.ID: true}
	for _, h := range remote {
		if h.ID != "" && h.ID == local.ID {
			hosts[0].Label = h.Label
			continue
		}
		if h.ID != "" && seen[h.ID] {
			continue
		}
		seen[h.ID] = true
		hosts = append(hosts, h)
	}
	return hosts
}

// Pane is one Rex terminal block and what runs in it.
type Pane struct {
	Host, Server            string
	SessionID, SessionLabel string
	WindowID, WindowLabel   string
	BlockID, Label          string
	Program                 string // foreground process name
	Agent                   string // amp, claude, codex, or "" for any other program
	Cwd                     string
	Title                   string
	State                   string // program status: idle, working, done, blocked, error, or ""
	Kind                    string // with blocked: permission, question, auth
	Msg                     string
	Since                   time.Time // when State last changed
	Ports                   []int
}

// IsAgent reports whether a coding agent runs in the pane, whether Amp or
// Claude Code or Codex started straight from the shell.
func (p Pane) IsAgent() bool { return p.Agent != "" }

// agentOf names the agent a process is from its name, argv0, and paths. The
// native Claude Code binary is named after its version, such as 2.1.328, so
// its name alone doesn't tell.
func agentOf(names ...string) string {
	for _, n := range names {
		switch filepath.Base(n) {
		case "amp":
			return "amp"
		case "claude":
			return "claude"
		case "codex":
			return "codex"
		}
	}
	return ""
}

type Session struct {
	Host      string
	ID, Label string
	Windows   int
	Panes     int
	Agents    int
}

type RexSnapshot struct {
	Hosts    []Host // with Err set on the hosts that failed this time
	Sessions []Session
	Panes    []Pane // terminal panes, agents first
	At       time.Time
}

type sessionView struct {
	SessionID string `json:"session_id"`
	Label     string `json:"label"`
	Windows   []struct {
		WindowID string `json:"window_id"`
		Label    string `json:"label"`
		Layers   []struct {
			Blocks []struct {
				BlockID     string `json:"block_id"`
				Label       string `json:"label"`
				CreatorName string `json:"creator_name"`
			} `json:"blocks"`
		} `json:"layers"`
	} `json:"windows"`
}

// rexArgs prefixes args with -S server when server names another host.
func rexArgs(server string, args ...string) []string {
	if server == "" {
		return args
	}
	return append([]string{"-S", server}, args...)
}

func rexJSON(ctx context.Context, server string, v any, args ...string) error {
	out, err := run(ctx, 10*time.Second, "rex", rexArgs(server, args...)...)
	if err != nil {
		return err
	}
	return json.Unmarshal(out, v)
}

// fetchRex reads every host at once. It fails only when no host answers, so
// one machine going to sleep leaves the others on screen.
func fetchRex(ctx context.Context, hosts []Host) (RexSnapshot, error) {
	parts := make([]RexSnapshot, len(hosts))
	errs := make([]error, len(hosts))
	var wg sync.WaitGroup
	for i, h := range hosts {
		wg.Add(1)
		go func() {
			defer wg.Done()
			parts[i], errs[i] = fetchHost(ctx, h)
		}()
	}
	wg.Wait()

	snap := RexSnapshot{At: time.Now()}
	var firstErr error
	for i, h := range hosts {
		h.Err = errs[i]
		snap.Hosts = append(snap.Hosts, h)
		if errs[i] != nil {
			firstErr = cmp.Or(firstErr, errs[i])
			continue
		}
		snap.Sessions = append(snap.Sessions, parts[i].Sessions...)
		snap.Panes = append(snap.Panes, parts[i].Panes...)
	}
	if len(snap.Sessions) == 0 && firstErr != nil {
		return snap, firstErr
	}
	sort.SliceStable(snap.Panes, func(i, j int) bool {
		a, b := snap.Panes[i], snap.Panes[j]
		if a.IsAgent() != b.IsAgent() {
			return a.IsAgent()
		}
		if a.Host != b.Host {
			return a.Host < b.Host
		}
		if a.SessionLabel != b.SessionLabel {
			return a.SessionLabel < b.SessionLabel
		}
		if isAmpRunner(a) != isAmpRunner(b) {
			return isAmpRunner(b) // runners host other threads, so list them last
		}
		return a.BlockID < b.BlockID
	})
	return snap, nil
}

func fetchHost(ctx context.Context, h Host) (RexSnapshot, error) {
	var ls struct {
		Sessions []struct {
			SessionID string `json:"session_id"`
			Label     string `json:"label"`
		} `json:"sessions"`
	}
	if err := rexJSON(ctx, h.Server, &ls, "ls", "--json"); err != nil {
		return RexSnapshot{}, err
	}

	var snap RexSnapshot
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)

	for _, s := range ls.Sessions {
		var view sessionView
		if err := rexJSON(ctx, h.Server, &view, "session", "inspect", s.SessionID, "--json"); err != nil {
			continue // the session may have just closed
		}
		sess := Session{Host: h.Label, ID: s.SessionID, Label: s.Label, Windows: len(view.Windows)}
		for _, w := range view.Windows {
			for _, l := range w.Layers {
				for _, b := range l.Blocks {
					if b.CreatorName != terminalCreator {
						continue
					}
					sess.Panes++
					p := Pane{
						Host: h.Label, Server: h.Server,
						SessionID: s.SessionID, SessionLabel: s.Label,
						WindowID: w.WindowID, WindowLabel: w.Label,
						BlockID: b.BlockID, Label: b.Label,
					}
					wg.Add(1)
					go func() {
						defer wg.Done()
						sem <- struct{}{}
						defer func() { <-sem }()
						inspectPane(ctx, &p)
						mu.Lock()
						snap.Panes = append(snap.Panes, p)
						mu.Unlock()
					}()
				}
			}
		}
		snap.Sessions = append(snap.Sessions, sess)
	}
	wg.Wait()

	for i := range snap.Sessions {
		for _, p := range snap.Panes {
			if p.SessionID == snap.Sessions[i].ID && p.IsAgent() {
				snap.Sessions[i].Agents++
			}
		}
	}
	return snap, nil
}

func inspectPane(ctx context.Context, p *Pane) {
	call := func(v any, method string) {
		_ = rexJSON(ctx, p.Server, v, "block", "call", "-s", p.SessionID, "-b", p.BlockID, method)
	}

	var proc struct {
		Foreground *struct {
			Name        string `json:"name"`
			Argv0       string `json:"argv0"`
			InvokedPath string `json:"invoked_path"`
			Path        string `json:"path"`
			Cwd         string `json:"cwd"`
		} `json:"foreground"`
	}
	call(&proc, "process")
	if f := proc.Foreground; f != nil {
		p.Program, p.Cwd = f.Name, f.Cwd
		p.Agent = agentOf(f.Name, f.Argv0, f.InvokedPath, f.Path)
	}

	var title struct {
		Title string `json:"title"`
	}
	call(&title, "title")
	p.Title = title.Title

	var status struct {
		Records []struct {
			ID    string    `json:"id"`
			State string    `json:"state"`
			Kind  string    `json:"kind"`
			Msg   string    `json:"msg"`
			At    time.Time `json:"updated_at"`
		} `json:"records"`
	}
	call(&status, "program_status")
	// Prefer the most urgent record, so a blocked child beats a working root.
	best := -1
	for _, r := range status.Records {
		if rank := stateRank(r.State); rank > best {
			best = rank
			p.State, p.Kind, p.Msg, p.Since = r.State, r.Kind, r.Msg, r.At
		}
	}

	if p.IsAgent() {
		var ports struct {
			Ports []json.RawMessage `json:"ports"`
		}
		call(&ports, "ports")
		for _, raw := range ports.Ports {
			var n int
			if json.Unmarshal(raw, &n) == nil {
				p.Ports = append(p.Ports, n)
				continue
			}
			var o struct {
				Port int `json:"port"`
			}
			if json.Unmarshal(raw, &o) == nil && o.Port > 0 {
				p.Ports = append(p.Ports, o.Port)
			}
		}
	}
}

func stateRank(s string) int {
	switch s {
	case "blocked":
		return 5
	case "error":
		return 4
	case "done":
		return 3
	case "working":
		return 2
	case "idle":
		return 1
	}
	return 0
}

// watchRex sends on changed whenever a host's Rex server reports an event that
// may change what the HUD shows. It reconnects if the stream ends, such as
// when the machine sleeps.
func watchRex(ctx context.Context, server string, changed chan<- struct{}) {
	for ctx.Err() == nil {
		cmd := exec.CommandContext(ctx, "rex", rexArgs(server, "events", "--all", "--json")...)
		out, err := cmd.StdoutPipe()
		if err == nil && cmd.Start() == nil {
			sc := bufio.NewScanner(out)
			sc.Buffer(make([]byte, 1<<20), 1<<20)
			for sc.Scan() {
				line := sc.Text()
				if strings.Contains(line, `"client_`) && !strings.Contains(line, "session_event") {
					continue // clients joining and leaving, including our own CLI calls
				}
				if strings.Contains(line, `"client_connected"`) || strings.Contains(line, `"client_disconnected"`) || strings.Contains(line, `"block_owner_changed"`) {
					continue
				}
				select {
				case changed <- struct{}{}:
				default:
				}
			}
			_ = cmd.Wait()
		}
		select {
		case <-ctx.Done():
		case <-time.After(10 * time.Second):
		}
	}
}

// focusPane focuses a pane's block on its host and asks the Rex app to show
// its session and tab. The app picks the tab it shows itself, even within the
// HUD's own session, so focusing the block alone leaves the tab unchanged.
// Selecting needs Remote Control turned on in the app and, with several apps
// connected, client. The app only shows panes of hosts it is connected to.
func focusPane(ctx context.Context, p Pane, client string) error {
	if _, err := run(ctx, 10*time.Second, "rex", rexArgs(p.Server, "focus", "-s", p.SessionID, p.BlockID)...); err != nil {
		return err
	}
	args := []string{"do", "session.select", "session_id=" + p.SessionID, "window_id=" + p.WindowID}
	if client != "" {
		args = append([]string{"-C", client}, args...)
	}
	_, err := run(ctx, 10*time.Second, "rex", rexArgs(p.Server, args...)...)
	return err
}
