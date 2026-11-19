package main

import (
	"os"
	"testing"
)

// usage.md is real `amp usage --details` output. The HUD depends on its
// Markdown layout, so this fails if an Amp update changes it.
func TestParseUsage(t *testing.T) {
	md, err := os.ReadFile("testdata/usage.md")
	if err != nil {
		t.Fatal(err)
	}
	u := parseUsage(string(md))
	if u.Credits != "Individual credits: $9.99 remaining" || u.CreditsUSD != 9.99 {
		t.Errorf("credits = %q, %v", u.Credits, u.CreditsUSD)
	}
	if u.TotalTokens != "1,307,836" || u.TotalCost != "$0.005" {
		t.Errorf("totals = %q, %q", u.TotalTokens, u.TotalCost)
	}
	models := u.Tables["Models"]
	if len(models) != 1 || models[0][0] != "Opus 5.5" || len(models[0]) != 7 {
		t.Errorf("models = %v", models)
	}
	top := u.Tables["Top Threads by Tokens"]
	if len(top) != 2 || threadIDRe.FindString(top[0][0]) != "T-01a1f207-0418-7029-a6f2-9d659bcca151" || top[1][1] != "64,421" {
		t.Errorf("top threads = %v", top)
	}
	if days := u.Tables["Daily Recorded Cost"]; len(days) != 1 || days[0][0] != "2026-11-19" {
		t.Errorf("daily = %v", days)
	}
}
