package main

import "testing"

// The processes Rex reported for real agent panes, as name, argv0,
// invoked_path, and path.
func TestAgentOf(t *testing.T) {
	cases := []struct {
		want  string
		names []string
	}{
		{"claude", []string{"2.1.328", "claude", "/Users/me/.local/bin/claude", "/Users/me/.local/share/claude/versions/2.1.328"}},
		{"claude", []string{"claude", "claude", "/opt/homebrew/bin/claude", "/opt/homebrew/Caskroom/claude-code/2.1.300/claude"}},
		{"codex", []string{"codex", "codex", "/Users/me/.local/bin/codex", "/Users/me/.codex/packages/standalone/releases/0.170.0-aarch64-apple-darwin/bin/codex"}},
		{"amp", []string{"amp", "amp", "/Users/me/.local/bin/amp", "/Users/me/.amp/bin/amp"}},
		{"", []string{"zsh", "-zsh", "/bin/zsh", "/bin/zsh"}},
		{"", []string{"rexamp", "/Users/me/.local/bin/amp-rex-hud", "/Users/me/.local/bin/amp-rex-hud", "/Users/me/.local/bin/rexamp"}},
	}
	for _, c := range cases {
		if got := agentOf(c.names...); got != c.want {
			t.Errorf("agentOf(%q) = %q, want %q", c.names, got, c.want)
		}
	}
}
