package main

import (
	"os"
	"reflect"
	"strings"
	"testing"
)

// The prompt files are real screens of Claude Code and Codex asking for
// permission. The notch app's buttons depend on reading them, so this fails if
// an agent update changes their layout.
func TestParsePrompt(t *testing.T) {
	cases := []struct {
		file string
		want Prompt
	}{
		{"prompt-claude-edit.txt", Prompt{
			Question: "Do you want to make this edit to a.txt?",
			Options: []Option{
				{"1", "Yes", ""},
				{"2", "Yes, and switch to accept edits (auto-approve file edits and common file commands) for this session", ""},
				{"3", "No", ""},
			},
			Preview: []string{"Edit file", "a.txt", "1 -hello world", "1 +goodbye world"},
		}},
		{"prompt-codex-command.txt", Prompt{
			Question: "Would you like to run the following command?",
			Options: []Option{
				{"1", "Yes, proceed", ""},
				{"2", "Yes, and don't ask again for commands that start with `printf '%s' hi > b.txt`", ""},
				{"3", "No, and tell Codex what to do differently", ""},
			},
			Preview: []string{"Environment: local", "", "Reason: May I write hi to b.txt in the read-only workspace?", "", "$ printf '%s' hi > b.txt"},
		}},
		{"prompt-claude-question.txt", Prompt{
			Question: "Which deployment target do you want?",
			Options: []Option{
				{"1", "Production", "Deploy to the production environment."},
				{"2", "Staging", "Deploy to the staging environment."},
				{"3", "Local only", "Keep it local; don't deploy anywhere."},
				{"4", "Type something.", ""},
				{"5", "Chat about this", ""},
			},
		}},
	}
	for _, c := range cases {
		screen, err := os.ReadFile("testdata/" + c.file)
		if err != nil {
			t.Fatal(err)
		}
		got := parsePrompt(string(screen))
		if got == nil || !reflect.DeepEqual(*got, c.want) {
			t.Errorf("%s:\ngot  %#v\nwant %#v", c.file, got, c.want)
		}
	}

	// Numbered lines in an agent's answer are not a menu.
	if p := parsePrompt("Steps:\n1. Build\n3. Ship\n\n❯ "); p != nil {
		t.Errorf("list parsed as menu: %#v", p)
	}
}

func TestChooseKeys(t *testing.T) {
	pr := &Prompt{Options: make([]Option, 3), Selected: 1}
	for i, want := range [][]string{{"up", "enter"}, {"enter"}, {"down", "enter"}} {
		if got := chooseKeys(pr, i); !reflect.DeepEqual(got, want) {
			t.Errorf("chooseKeys(%d) = %v, want %v", i, got, want)
		}
	}
}

// The done-*.txt screens are real: each agent finished its turn by asking
// a question in plain text, except Amp's, which ends with a statement.
func TestLastQuestion(t *testing.T) {
	read := func(name string) string {
		b, err := os.ReadFile("testdata/" + name)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	want := "Which name do you prefer for the project, Juniper or Basalt?"
	for _, name := range []string{"done-claude.txt", "done-codex.txt"} {
		if got := lastQuestion(read(name)); got != want {
			t.Errorf("%s: lastQuestion = %q, want %q", name, got, want)
		}
	}
	amp := read("done-amp.txt")
	if got := lastQuestion(amp); got != "" {
		t.Errorf("done-amp.txt: lastQuestion = %q, want none", got)
	}
	// The same screen ending in a question; earlier questions don't count.
	asked := strings.Replace(amp, "if you find you miss questions.", "if you miss questions?", 1)
	if got := lastQuestion(asked); got != "I'd do 1 now, and add 2 later if you miss questions?" {
		t.Errorf("amp question = %q", got)
	}
	// The user's own message, with nothing after it, is not the agent's.
	if got := lastQuestion("┃ Should I?\n\n╭──────────\n│\n╰──────────"); got != "" {
		t.Errorf("user message = %q", got)
	}
}
