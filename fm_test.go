package main

import (
	"os"
	"testing"
)

// The fm files are real screens of `fm chat`: thinking about a message,
// writing its reply, and finished with and without a question.
func TestParseFM(t *testing.T) {
	cases := []struct {
		file string
		want fmChat
	}{
		{"thinking-fm.txt", fmChat{State: "working", Task: "Write 200 words about moss. End by asking which moss I like best?"}},
		{"working-fm.txt", fmChat{State: "working", Task: "Write 200 words about moss. End by asking which moss I like best?"}},
		{"question-fm.txt", fmChat{State: "done", Task: "Write 200 words about moss. End by asking which moss I like best?", Question: "Which moss do you like best?"}},
		{"done-fm.txt", fmChat{State: "done", Task: "Reply with exactly a markdown blockquote of a two-line famous quote, then the author, then ask if I want another one. This prompt is deliberately long so that it wraps across more than one line of"}},
	}
	for _, c := range cases {
		b, err := os.ReadFile("testdata/" + c.file)
		if err != nil {
			t.Fatal(err)
		}
		got, ok := parseFM(string(b))
		if !ok || got != c.want {
			t.Errorf("%s: got %+v, %v; want %+v", c.file, got, ok, c.want)
		}
	}
}

func TestParseFMNotChat(t *testing.T) {
	if _, ok := parseFM("$ fm respond 'hi'\n Hello! How can I help?\n"); ok {
		t.Error("fm respond read as a chat")
	}
	got, ok := parseFM("$ fm chat\n\n Foundation Models Chat\n model: system · /help for help\n╭───╮\n│ > │\n╰───╯\n system (AFM 3 Core Advanced)\n")
	if !ok || got.State != "idle" {
		t.Errorf("new chat: got %+v, %v; want idle", got, ok)
	}
}

func TestAgentOfFM(t *testing.T) {
	if got := agentOf("fm", "fm", "/usr/bin/fm"); got != "fm" {
		t.Errorf("agentOf(fm) = %q", got)
	}
}
