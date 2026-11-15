package core

import "testing"

func TestGoggles(t *testing.T) {
	in := []WebResult{
		{Title: "Best laptops to buy", URL: "https://www.amazon.com/x"},
		{Title: "Go docs", URL: "https://go.dev/doc/"},
		{Title: "Thread", URL: "https://www.reddit.com/r/golang/comments/1"},
		{Title: "Q", URL: "https://stackoverflow.com/questions/1"},
		{Title: "Forum post", URL: "https://forum.example.org/t/42"},
		{Title: "Blog", URL: "https://jane.example.net/post"},
		{Title: "Paper", URL: "https://arxiv.org/abs/1"},
	}
	rs := Rank(in, "go generics", nil)
	f := ApplyGoggle(rs, "forums")
	if len(f) != 3 {
		t.Fatalf("forums: %d links: %v", len(f), f)
	}
	for _, r := range f {
		if fits("forums", r) != 1 {
			t.Fatalf("not a forum: %s", r.URL)
		}
	}
	for _, r := range ApplyGoggle(rs, "noshop") {
		if r.Label == "Shop" {
			t.Fatal("a shop stayed")
		}
	}
	if ind := ApplyGoggle(rs, "indie"); Host(ind[0].URL) != "jane.example.net" && Host(ind[0].URL) != "forum.example.org" {
		t.Fatalf("small web should lead: %s", ind[0].URL)
	}
	if len(ApplyGoggle(rs, "")) != len(rs) {
		t.Fatal("All keeps everything")
	}
	if TopicOf("how to install niri").Label != "How-to" || TopicOf("what is a vector database").Label != "Code" || TopicOf("weather").Label != "Travel" {
		t.Fatal("topics")
	}
	if SourceQuality([]WebResult{{URL: "https://en.wikipedia.org/a"}, {URL: "https://go.dev/b"}, {URL: "https://arxiv.org/c"}}, "") != 2 {
		t.Fatal("strong sources")
	}
}
