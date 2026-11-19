package main

import (
	"bufio"
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// DesktopSession is an agent session in the Claude or ChatGPT desktop app.
// Neither app runs in a Rex pane, so the HUD reads what each leaves on disk.
type DesktopSession struct {
	ID    string
	App   string // claude or chatgpt
	Task  string
	Cwd   string
	State string // working, blocked, done, or idle, as for panes
	Kind  string // with blocked: permission or question
	Since time.Time
}

func appName(app string) string {
	if app == "chatgpt" {
		return "ChatGPT"
	}
	return "Claude"
}

// appBundleID is the app to bring forward when a session is clicked.
func appBundleID(app string) string {
	if app == "chatgpt" {
		return "com.openai.codex"
	}
	return "com.anthropic.claudefordesktop"
}

func fetchDesktop(ctx context.Context) ([]DesktopSession, error) {
	out := claudeDesktopSessions()
	codex, err := chatgptSessions(ctx)
	out = append(out, codex...)
	slices.SortStableFunc(out, func(a, b DesktopSession) int { return b.Since.Compare(a.Since) })
	return out, err
}

// claudeDesktopSessions reads Claude Code's registry of running sessions,
// ~/.claude/sessions/<pid>.json, which the Claude app's sessions are in
// too, and keeps the app's ones whose process is still alive. Terminal
// sessions are left to the Rex panes.
func claudeDesktopSessions() []DesktopSession {
	files, _ := filepath.Glob(filepath.Join(homeDir, ".claude", "sessions", "*.json"))
	var out []DesktopSession
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var r struct {
			PID             int    `json:"pid"`
			SessionID       string `json:"sessionId"`
			Cwd             string `json:"cwd"`
			Entrypoint      string `json:"entrypoint"`
			Name            string `json:"name"`
			Status          string `json:"status"` // busy, waiting, or idle
			WaitingFor      string `json:"waitingFor"`
			StatusUpdatedAt int64  `json:"statusUpdatedAt"`
		}
		if json.Unmarshal(b, &r) != nil || r.Entrypoint != "claude-desktop" || r.PID <= 0 || syscall.Kill(r.PID, 0) != nil {
			continue
		}
		s := DesktopSession{ID: r.SessionID, App: "claude", Task: cmp.Or(r.Name, "new session"), Cwd: r.Cwd, State: "idle"}
		if r.StatusUpdatedAt > 0 {
			s.Since = time.UnixMilli(r.StatusUpdatedAt)
		}
		switch r.Status {
		case "busy":
			s.State = "working"
		case "waiting":
			s.State = "blocked"
			s.Kind = "question"
			if strings.Contains(strings.ToLower(r.WaitingFor), "permission") {
				s.Kind = "permission"
			}
		}
		out = append(out, s)
	}
	return out
}

// chatgptSessions lists recent threads of the ChatGPT (Codex) app while it
// runs. The app keeps its own app server, so their state comes from each
// thread's rollout file: a turn that started and hasn't completed is working.
// Rollouts don't record waiting for approval, so that shows as working too.
func chatgptSessions(ctx context.Context) ([]DesktopSession, error) {
	if _, err := run(ctx, 5*time.Second, "pgrep", "-x", "ChatGPT"); err != nil {
		return nil, nil // not running
	}
	db := filepath.Join(homeDir, ".codex", "state_5.sqlite")
	since := time.Now().Add(-12 * time.Hour).UnixMilli()
	q := `select id, cwd, coalesce(nullif(name,''), title) as title, rollout_path, updated_at_ms from threads
	      where originator = 'Codex Desktop' and source = 'vscode' and archived = 0 and updated_at_ms > ` + strconv.FormatInt(since, 10) + `
	      order by updated_at_ms desc limit 8`
	b, err := run(ctx, 10*time.Second, "sqlite3", "-readonly", "-json", db, q)
	if err != nil {
		return nil, err
	}
	var rows []struct {
		ID      string `json:"id"`
		Cwd     string `json:"cwd"`
		Title   string `json:"title"`
		Rollout string `json:"rollout_path"`
		Updated int64  `json:"updated_at_ms"`
	}
	if len(bytes.TrimSpace(b)) > 0 {
		if err := json.Unmarshal(b, &rows); err != nil {
			return nil, err
		}
	}
	var out []DesktopSession
	for _, r := range rows {
		state, at := rolloutState(r.Rollout)
		if at.IsZero() {
			at = time.UnixMilli(r.Updated)
		}
		out = append(out, DesktopSession{ID: r.ID, App: "chatgpt", Task: cmp.Or(r.Title, "new thread"), Cwd: r.Cwd, State: state, Since: at})
	}
	return out, nil
}

// rolloutState reads the end of a Codex rollout for its last turn event:
// working after task_started, done for half an hour after task_complete,
// then idle.
func rolloutState(path string) (string, time.Time) {
	f, err := os.Open(path)
	if err != nil {
		return "idle", time.Time{}
	}
	defer f.Close()
	if st, err := f.Stat(); err == nil && st.Size() > 512<<10 {
		f.Seek(-512<<10, io.SeekEnd)
	}
	state, at := "idle", time.Time{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 4<<20), 4<<20)
	for sc.Scan() {
		line := sc.Bytes()
		started := bytes.Contains(line, []byte(`"type":"task_started"`))
		if !started && !bytes.Contains(line, []byte(`"type":"task_complete"`)) {
			continue
		}
		var e struct {
			Timestamp time.Time `json:"timestamp"`
			Type      string    `json:"type"`
		}
		if json.Unmarshal(line, &e) != nil || e.Type != "event_msg" {
			continue
		}
		state, at = "done", e.Timestamp
		if started {
			state = "working"
		}
	}
	if state == "done" && time.Since(at) > 30*time.Minute {
		state = "idle"
	}
	return state, at
}
