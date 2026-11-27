package main

import (
	"context"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
)

// procTree is this machine's processes, read once a snapshot, to find an
// agent that a harness or script runs headless in a pane: there the pane's
// foreground program is the harness, and Claude Code or Codex is below it.
type procTree struct {
	args     map[int][]string // the first words of each process's command line
	children map[int][]int
}

func readProcTree(ctx context.Context) *procTree {
	out, err := run(ctx, 5*time.Second, "ps", "-A", "-o", "pid=,ppid=,args=")
	if err != nil {
		return nil
	}
	return parseProcTree(string(out))
}

func parseProcTree(s string) *procTree {
	t := &procTree{args: map[int][]string{}, children: map[int][]int{}}
	for _, line := range strings.Split(s, "\n") {
		f := strings.Fields(line)
		if len(f) < 3 {
			continue
		}
		pid, err1 := strconv.Atoi(f[0])
		ppid, err2 := strconv.Atoi(f[1])
		if err1 != nil || err2 != nil {
			continue
		}
		t.args[pid] = f[2:min(len(f), 4)]
		t.children[ppid] = append(t.children[ppid], pid)
	}
	for _, c := range t.children {
		slices.Sort(c)
	}
	return t
}

// agentUnder finds the nearest Claude Code or Codex process below pid. It
// returns "" when there is none.
func (t *procTree) agentUnder(pid int) (agent string, agentPID int) {
	if t == nil {
		return "", 0
	}
	queue := slices.Clone(t.children[pid])
	seen := map[int]bool{pid: true}
	for len(queue) > 0 {
		p := queue[0]
		queue = queue[1:]
		if seen[p] {
			continue
		}
		seen[p] = true
		if a := headlessAgentOf(t.args[p]); a != "" {
			return a, p
		}
		queue = append(queue, t.children[p]...)
	}
	return "", 0
}

// headlessAgentOf names the agent a command line runs: the program itself,
// or the script a JavaScript runtime runs, as for Codex installed with npm.
// Arguments aren't looked at otherwise, so `grep claude` isn't an agent.
func headlessAgentOf(args []string) string {
	if len(args) == 0 {
		return ""
	}
	names := args[:1]
	switch filepath.Base(args[0]) {
	case "node", "bun", "deno":
		names = args
	}
	switch a := agentOf(names...); a {
	case "claude", "codex":
		return a
	}
	return ""
}
