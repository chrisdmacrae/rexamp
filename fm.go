package main

import (
	"regexp"
	"strconv"
	"strings"
)

// Apple's Foundation Models CLI, fm, reports no status and sets no title, so
// what an `fm chat` session is doing comes from its screen. It shows each
// message you send as " > …" at the left edge, and once a reply has finished,
// "turn N" in the footer under its input box, counting the finished replies.
// A message without a finished reply yet is being answered.
var fmTurnRe = regexp.MustCompile(`· turn ([\d,]+) ·`)

const fmChatHeader = "Foundation Models Chat"

// fmChat is what an fm chat session's screen shows.
type fmChat struct {
	State    string // working, done, or idle
	Task     string // the last message you sent
	Question string // with done: what the reply ended by asking
}

// parseFM reads an fm chat session from its screen and scrollback, from the
// last time a chat started in the pane. It reports false when the screen
// isn't an fm chat, such as `fm respond` or `fm serve`, which aren't
// sessions to track.
func parseFM(screen string) (fmChat, bool) {
	lines := strings.Split(screen, "\n")
	start := -1
	for i := len(lines) - 1; i >= 0; i-- {
		if strings.TrimSpace(lines[i]) == fmChatHeader {
			start = i
			break
		}
	}
	if start < 0 {
		return fmChat{}, false
	}
	lines = lines[start:]

	var c fmChat
	sent, turns := 0, 0
	for _, l := range lines {
		if strings.HasPrefix(l, " > ") {
			sent++
			c.Task = strings.TrimSpace(l[len(" > "):])
		} else if m := fmTurnRe.FindStringSubmatch(l); m != nil {
			turns, _ = strconv.Atoi(strings.ReplaceAll(m[1], ",", ""))
		}
	}

	switch {
	case sent > turns:
		c.State = "working"
	case sent > 0:
		c.State = "done"
		c.Question = lastQuestion(strings.Join(lines[max(0, len(lines)-60):], "\n"))
	default:
		c.State = "idle"
	}
	return c, true
}
