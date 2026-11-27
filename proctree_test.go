package main

import "testing"

func TestAgentUnderFindsHeadlessAgents(t *testing.T) {
	// A harness running Claude Code headless, a script running Codex from npm,
	// and a shell grepping for claude, as `ps -A -o pid=,ppid=,args=` shows them.
	tree := parseProcTree(`
  100     1 /Users/me/.local/bin/rux
  101   100 /Users/me/.local/bin/claude -p --output-format stream-json
  102   101 /bin/zsh -c make test
  200     1 /bin/sh ./run.sh
  201   200 /bin/sleep 1
  202   201 node /opt/homebrew/bin/codex exec fix it
  300     1 -zsh
  301   300 grep claude
`)
	cases := []struct {
		pid   int
		agent string
		at    int
	}{
		{100, "claude", 101},
		{200, "codex", 202},
		{300, "", 0},
		{999, "", 0},
	}
	for _, c := range cases {
		if a, p := tree.agentUnder(c.pid); a != c.agent || p != c.at {
			t.Errorf("agentUnder(%d) = %q, %d; want %q, %d", c.pid, a, p, c.agent, c.at)
		}
	}
	var none *procTree
	if a, _ := none.agentUnder(100); a != "" {
		t.Errorf("nil tree found %q", a)
	}
}
