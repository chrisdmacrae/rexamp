package main

import (
	"context"
	"encoding/json"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Usage is what the HUD shows from `amp usage --details`, which prints
// Markdown only, so it is parsed from the text.
type Usage struct {
	Credits     string                // e.g. "Individual credits: $10.00 remaining"
	CreditsUSD  float64               // first dollar amount on the credits line, -1 if unknown
	TotalTokens string                // trailing 7 days
	TotalCost   string                // trailing 7 days
	Tables      map[string][][]string // "## Heading" -> rows (header row excluded)
	FetchedAt   time.Time
}

type Thread struct {
	ID           string    `json:"id"`
	Title        string    `json:"title"`
	Updated      time.Time `json:"updated"`
	Tree         string    `json:"tree"`
	MessageCount int       `json:"messageCount"`
}

var (
	creditsRe = regexp.MustCompile(`\*\*([^*]*credits):\*\*\s*([^\n(]+?)\s*(?:\(|- https|$)`)
	dollarRe  = regexp.MustCompile(`\$([\d,]+(?:\.\d+)?)`)
	tokensRe  = regexp.MustCompile(`(?m)^Total tokens:\s*(.+)$`)
	costRe    = regexp.MustCompile(`(?m)^Total recorded cost:\s*(.+)$`)
)

func parseUsage(md string) Usage {
	u := Usage{CreditsUSD: -1, Tables: map[string][][]string{}, FetchedAt: time.Now()}
	if m := creditsRe.FindStringSubmatch(md); m != nil {
		u.Credits = strings.TrimSpace(m[1] + ": " + m[2])
		if d := dollarRe.FindStringSubmatch(m[2]); d != nil {
			u.CreditsUSD = parseNumber(d[1])
		}
	}
	if m := tokensRe.FindStringSubmatch(md); m != nil {
		u.TotalTokens = strings.TrimSpace(m[1])
	}
	if m := costRe.FindStringSubmatch(md); m != nil {
		u.TotalCost = strings.TrimSpace(m[1])
	}

	heading := ""
	sawHeader := false
	for _, line := range strings.Split(md, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "## "):
			heading = strings.TrimPrefix(line, "## ")
			sawHeader = false
		case strings.HasPrefix(line, "|") && heading != "":
			cells := splitRow(line)
			if !sawHeader {
				sawHeader = true // first row is the header
				continue
			}
			if isSeparator(cells) {
				continue
			}
			u.Tables[heading] = append(u.Tables[heading], cells)
		}
	}
	return u
}

func splitRow(line string) []string {
	parts := strings.Split(strings.Trim(line, "|"), "|")
	for i := range parts {
		parts[i] = strings.TrimSpace(parts[i])
	}
	return parts
}

func isSeparator(cells []string) bool {
	for _, c := range cells {
		if strings.Trim(c, "-: ") != "" {
			return false
		}
	}
	return true
}

// parseNumber reads "$1,234.50" or "209,185" as a number, 0 if it isn't one.
func parseNumber(s string) float64 {
	f, _ := strconv.ParseFloat(strings.NewReplacer(",", "", "$", "").Replace(s), 64)
	return f
}

func fetchUsage(ctx context.Context) (Usage, error) {
	out, err := run(ctx, 45*time.Second, "amp", "usage", "--details")
	if err != nil {
		return Usage{}, err
	}
	return parseUsage(string(out)), nil
}

func fetchThreads(ctx context.Context, limit int) ([]Thread, error) {
	out, err := run(ctx, 30*time.Second, "amp", "threads", "list", "--json", "--limit", strconv.Itoa(limit))
	if err != nil {
		return nil, err
	}
	var ts []Thread
	return ts, json.Unmarshal(out, &ts)
}

func run(ctx context.Context, timeout time.Duration, name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.Output()
	if ee, ok := err.(*exec.ExitError); ok && len(ee.Stderr) > 0 {
		return out, &cmdError{name + " " + strings.Join(args, " "), strings.TrimSpace(string(ee.Stderr))}
	}
	return out, err
}

type cmdError struct{ cmd, msg string }

func (e *cmdError) Error() string { return e.cmd + ": " + e.msg }
