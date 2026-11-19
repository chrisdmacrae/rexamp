package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The lines are in the format of real ChatGPT (Codex) app rollouts. The HUD
// reads their turn events, so this fails if an update renames them.
func TestRolloutState(t *testing.T) {
	ts := func(ago time.Duration) string { return time.Now().Add(-ago).UTC().Format(time.RFC3339Nano) }
	started := func(ago time.Duration) string {
		return `{"timestamp":"` + ts(ago) + `","ordinal":1,"type":"event_msg","payload":{"type":"task_started","turn_attribution":{"turn_id":"t","turn_trigger":"user"}}}`
	}
	complete := func(ago time.Duration) string {
		return `{"timestamp":"` + ts(ago) + `","ordinal":40,"type":"event_msg","payload":{"type":"task_complete","turn_id":"t","last_agent_message":"Created b.txt"}}`
	}
	// A tool call whose output quotes an event name must not count.
	quoted := `{"timestamp":"` + ts(0) + `","type":"response_item","payload":{"type":"function_call_output","output":"{\"type\":\"task_complete\"}"}}`

	cases := []struct {
		name  string
		lines []string
		want  string
	}{
		{"turn running", []string{complete(time.Hour), started(time.Minute), quoted}, "working"},
		{"turn just finished", []string{started(3 * time.Minute), complete(2 * time.Minute)}, "done"},
		{"finished long ago", []string{started(2 * time.Hour), complete(time.Hour)}, "idle"},
		{"no turns", []string{`{"timestamp":"` + ts(0) + `","type":"session_meta","payload":{}}`}, "idle"},
	}
	for _, c := range cases {
		f := filepath.Join(t.TempDir(), "rollout.jsonl")
		os.WriteFile(f, []byte(strings.Join(c.lines, "\n")+"\n"), 0o644)
		if got, _ := rolloutState(f); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}
