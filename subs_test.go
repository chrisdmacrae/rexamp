package main

import (
	"testing"
	"time"
)

// These are trimmed real responses. The endpoints are undocumented, so this
// fails if Anthropic or OpenAI change their shape.
func TestParseSubUsage(t *testing.T) {
	claude := `{"five_hour":{"utilization":4.0,"resets_at":"2026-11-20T00:49:59.793898+00:00"},
		"seven_day":{"utilization":12.0,"resets_at":"2026-11-21T19:59:59.793928+00:00"},
		"seven_day_opus":null,"limits":[{"kind":"session","percent":4}],"extra_usage":{"is_enabled":false},"seven_day_sonnet":{"utilization":30.5,"resets_at":"2026-11-21T19:59:59+00:00"}}`
	ws, err := parseClaudeUsage([]byte(claude))
	if err != nil {
		t.Fatal(err)
	}
	if len(ws) != 3 || ws[0].Label != "5-hour" || ws[0].Percent != 4 || ws[1].Label != "weekly" || ws[2].Label != "weekly Sonnet" || ws[2].Percent != 30.5 {
		t.Errorf("claude = %+v", ws)
	}
	if want := time.Date(2026, 11, 21, 19, 59, 59, 793928000, time.UTC); !ws[1].ResetsAt.Equal(want) {
		t.Errorf("claude weekly resets = %v", ws[1].ResetsAt)
	}

	codex := `{"plan_type":"prolite","rate_limit":{"allowed":true,
		"primary_window":{"used_percent":7,"limit_window_seconds":18000,"reset_after_seconds":320973,"reset_at":1795442920},
		"secondary_window":{"used_percent":61,"limit_window_seconds":604800,"reset_at":1795500000}}}`
	plan, ws, err := parseCodexUsage([]byte(codex))
	if err != nil {
		t.Fatal(err)
	}
	if plan != "prolite" || len(ws) != 2 || ws[0].Label != "5-hour" || ws[0].Percent != 7 || ws[1].Label != "weekly" || ws[1].Percent != 61 {
		t.Errorf("codex = %q %+v", plan, ws)
	}
	if !ws[0].ResetsAt.Equal(time.Unix(1795442920, 0)) {
		t.Errorf("codex resets = %v", ws[0].ResetsAt)
	}
}
