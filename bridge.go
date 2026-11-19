package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"
)

// RemoteThread is one thread as the amp-hud-bridge plugin reports it. State is
// idle, running, awaiting-approval, error, or unknown for a thread that isn't
// loaded anywhere right now.
type RemoteThread struct {
	ID      string    `json:"id"`
	Title   string    `json:"title"`
	Tree    string    `json:"tree"`
	Updated time.Time `json:"updated"`
	State   string    `json:"state"`
}

func bridgeURL() string {
	if p := os.Getenv("AMP_HUD_BRIDGE_PORT"); p != "" {
		return "http://127.0.0.1:" + p
	}
	return "http://127.0.0.1:7789"
}

func fetchBridge(ctx context.Context) ([]RemoteThread, error) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", bridgeURL(), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("bridge plugin not running (start amp, or see plugin/amp-hud-bridge.ts)")
	}
	defer resp.Body.Close()
	var body struct {
		Error   string         `json:"error"`
		Threads []RemoteThread `json:"threads"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, err
	}
	if body.Error != "" && body.Threads == nil {
		return nil, fmt.Errorf("bridge: %s", body.Error)
	}
	return body.Threads, nil
}

// hudState maps a thread state onto the program status states the Rex panes use.
func hudState(s string) string {
	switch s {
	case "running":
		return "working"
	case "awaiting-approval":
		return "blocked"
	case "error":
		return "error"
	case "idle":
		return "idle"
	}
	return ""
}
