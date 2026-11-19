package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"time"
)

// SubUsage is how much of a Claude or ChatGPT subscription's rate limits the
// user has spent, read from the same endpoints Claude Code's /usage and
// Codex's /status use, with the login each CLI saved.
type SubUsage struct {
	Name    string // Claude Code or Codex
	Plan    string // e.g. max, prolite
	Windows []LimitWindow
	Err     error
}

type LimitWindow struct {
	Label    string // 5-hour, weekly, weekly Opus…
	Percent  float64
	ResetsAt time.Time
}

// errNoLogin means the CLI isn't installed or isn't signed in to a
// subscription, so there is nothing to show.
var errNoLogin = errors.New("no subscription login")

// fetchSubs returns the subscriptions with a saved login, in a fixed order.
func fetchSubs(ctx context.Context) []SubUsage {
	var out []SubUsage
	for _, f := range []func(context.Context) (SubUsage, error){fetchClaudeUsage, fetchCodexUsage} {
		s, err := f(ctx)
		if errors.Is(err, errNoLogin) {
			continue
		}
		s.Err = err
		out = append(out, s)
	}
	return out
}

func fetchClaudeUsage(ctx context.Context) (SubUsage, error) {
	s := SubUsage{Name: "Claude Code"}
	// Claude Code keeps its login in the keychain on macOS, in a file elsewhere.
	var raw []byte
	if runtime.GOOS == "darwin" {
		raw, _ = run(ctx, 5*time.Second, "security", "find-generic-password", "-s", "Claude Code-credentials", "-w")
	}
	if len(raw) == 0 {
		home, _ := os.UserHomeDir()
		raw, _ = os.ReadFile(filepath.Join(home, ".claude", ".credentials.json"))
	}
	var creds struct {
		OAuth struct {
			AccessToken      string `json:"accessToken"`
			ExpiresAt        int64  `json:"expiresAt"` // ms
			SubscriptionType string `json:"subscriptionType"`
		} `json:"claudeAiOauth"`
	}
	if json.Unmarshal(raw, &creds) != nil || creds.OAuth.AccessToken == "" {
		return s, errNoLogin
	}
	s.Plan = creds.OAuth.SubscriptionType
	if exp := creds.OAuth.ExpiresAt; exp > 0 && time.UnixMilli(exp).Before(time.Now()) {
		return s, errors.New("login expired; open Claude Code to refresh it")
	}
	body, err := getJSON(ctx, "https://api.anthropic.com/api/oauth/usage", map[string]string{
		"Authorization":  "Bearer " + creds.OAuth.AccessToken,
		"anthropic-beta": "oauth-2025-04-20",
	})
	if err != nil {
		return s, err
	}
	s.Windows, err = parseClaudeUsage(body)
	return s, err
}

func parseClaudeUsage(body []byte) ([]LimitWindow, error) {
	type window struct {
		Utilization float64   `json:"utilization"`
		ResetsAt    time.Time `json:"resets_at"`
	}
	var u map[string]json.RawMessage // other fields are arrays and numbers
	if err := json.Unmarshal(body, &u); err != nil {
		return nil, err
	}
	var out []LimitWindow
	for _, k := range []struct{ key, label string }{
		{"five_hour", "5-hour"}, {"seven_day", "weekly"}, {"seven_day_opus", "weekly Opus"}, {"seven_day_sonnet", "weekly Sonnet"},
	} {
		var w *window
		if err := json.Unmarshal(u[k.key], &w); err == nil && w != nil {
			out = append(out, LimitWindow{k.label, w.Utilization, w.ResetsAt})
		}
	}
	return out, nil
}

func fetchCodexUsage(ctx context.Context) (SubUsage, error) {
	s := SubUsage{Name: "Codex"}
	dir := os.Getenv("CODEX_HOME")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".codex")
	}
	raw, _ := os.ReadFile(filepath.Join(dir, "auth.json"))
	var auth struct {
		Tokens struct {
			AccessToken string `json:"access_token"`
			AccountID   string `json:"account_id"`
		} `json:"tokens"`
	}
	// An API key login has no tokens and no subscription limits.
	if json.Unmarshal(raw, &auth) != nil || auth.Tokens.AccessToken == "" {
		return s, errNoLogin
	}
	body, err := getJSON(ctx, "https://chatgpt.com/backend-api/wham/usage", map[string]string{
		"Authorization":      "Bearer " + auth.Tokens.AccessToken,
		"ChatGPT-Account-Id": auth.Tokens.AccountID,
		"User-Agent":         "codex-cli",
	})
	if err != nil {
		return s, err
	}
	s.Plan, s.Windows, err = parseCodexUsage(body)
	return s, err
}

func parseCodexUsage(body []byte) (string, []LimitWindow, error) {
	type window struct {
		UsedPercent float64 `json:"used_percent"`
		Seconds     int64   `json:"limit_window_seconds"`
		ResetAt     int64   `json:"reset_at"`
	}
	var u struct {
		Plan      string `json:"plan_type"`
		RateLimit struct {
			Primary   *window `json:"primary_window"`
			Secondary *window `json:"secondary_window"`
		} `json:"rate_limit"`
	}
	if err := json.Unmarshal(body, &u); err != nil {
		return "", nil, err
	}
	var out []LimitWindow
	for _, w := range []*window{u.RateLimit.Primary, u.RateLimit.Secondary} {
		if w != nil {
			out = append(out, LimitWindow{windowLabel(time.Duration(w.Seconds) * time.Second), w.UsedPercent, time.Unix(w.ResetAt, 0)})
		}
	}
	return u.Plan, out, nil
}

func windowLabel(d time.Duration) string {
	switch {
	case d == 7*24*time.Hour:
		return "weekly"
	case d >= 24*time.Hour:
		return fmt.Sprintf("%d-day", int(d.Hours()/24))
	default:
		return fmt.Sprintf("%d-hour", int(d.Hours()))
	}
}

func getJSON(ctx context.Context, url string, headers map[string]string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	switch {
	case err != nil:
		return nil, err
	case resp.StatusCode == http.StatusUnauthorized:
		return nil, errors.New("login expired; sign in again")
	case resp.StatusCode != http.StatusOK:
		return nil, fmt.Errorf("usage request: %s", resp.Status)
	}
	return body, nil
}
