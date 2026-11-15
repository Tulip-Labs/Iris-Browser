package core

import (
	"regexp"
	"sort"
	"strings"
)

// Goggles re-rank the links of a search for one purpose, the way Brave
// Search's Goggles and Kagi's lenses do: the links a goggle wants come first,
// the ones it leaves out go (as long as enough remain to read).

// Goggle is one way of ranking.
type Goggle struct {
	ID, Label, Tip string
}

// Goggles are the choices shown over the results ("" is everything).
var Goggles = []Goggle{
	{"", "All", "Every link, ranked by source quality"},
	{"forums", "Forums", "Real discussions: Reddit, Stack Exchange, Hacker News, community forums"},
	{"academic", "Academic", "Research, universities, references and official sources"},
	{"tech", "Tech", "Documentation, code and developer answers"},
	{"news", "News", "News outlets"},
	{"indie", "Small web", "Personal sites and blogs first; big platforms last"},
	{"noshop", "No shops", "Without stores, coupons and listicles built to sell"},
}

var (
	forumHost = regexp.MustCompile(`(^|\.)(reddit\.com|stackexchange\.com|stackoverflow\.com|superuser\.com|serverfault\.com|askubuntu\.com|news\.ycombinator\.com|lobste\.rs|discourse\.[a-z.]+|quora\.com)$|(^|\.)(forum|forums|community|discuss|discussions|boards)\.`)
	forumPath = regexp.MustCompile(`(?i)/(forum|forums|community|discuss|discussion|thread|threads|t|questions|r)/`)
	techHost  = regexp.MustCompile(`(^|\.)(github\.com|gitlab\.com|codeberg\.org|dev\.to|stackoverflow\.com|readthedocs\.io|docs\.[a-z0-9.-]+|developer\.[a-z0-9.-]+|learn\.microsoft\.com|pkg\.go\.dev|npmjs\.com|pypi\.org|crates\.io|hub\.docker\.com|man7\.org)$`)
	bigHost   = regexp.MustCompile(`(^|\.)(wikipedia\.org|youtube\.com|reddit\.com|amazon\.[a-z.]+|facebook\.com|instagram\.com|linkedin\.com|pinterest\.[a-z.]+|quora\.com|medium\.com|forbes\.com|nytimes\.com|cnn\.com|bbc\.co\.uk|bbc\.com|microsoft\.com|apple\.com|google\.com|x\.com|twitter\.com|tiktok\.com|yahoo\.com|msn\.com|imdb\.com|ebay\.com|walmart\.com)$`)
)

// fits says how well link r suits goggle id: 1 wanted, 0 neutral, -1 left out.
func fits(id string, r Ranked) int {
	host := strings.TrimPrefix(strings.ToLower(Host(r.URL)), "www.")
	switch id {
	case "forums":
		if r.Label == "Discussion" || forumHost.MatchString(host) || forumPath.MatchString(r.URL) {
			return 1
		}
		return -1
	case "academic":
		switch r.Label {
		case "Research", "Academic", "Reference", "Official":
			return 1
		}
		return -1
	case "tech":
		if r.Label == "Docs" || techHost.MatchString(host) {
			return 1
		}
		if r.Label == "Discussion" {
			return 0
		}
		return -1
	case "news":
		if r.Label == "News" {
			return 1
		}
		return -1
	case "indie":
		if bigHost.MatchString(host) || r.Label == "Shop" || r.Label == "News" {
			return -1
		}
		if r.Label == "" {
			return 1
		}
		return 0
	case "noshop":
		if r.Label == "Shop" || adTitle.MatchString(r.Title) || buyIntent.MatchString(r.Title) {
			return -1
		}
	}
	return 0
}

// ApplyGoggle ranks rs for goggle id. Links the goggle leaves out are dropped
// when at least three wanted ones remain; otherwise they follow the wanted ones.
func ApplyGoggle(rs []Ranked, id string) []Ranked {
	if id == "" {
		return rs
	}
	type scored struct {
		r Ranked
		f int
	}
	var all []scored
	wanted := 0
	for _, r := range rs {
		f := fits(id, r)
		if f > 0 {
			wanted++
		}
		all = append(all, scored{r, f})
	}
	sort.SliceStable(all, func(i, j int) bool { return all[i].f > all[j].f })
	out := make([]Ranked, 0, len(all))
	for _, s := range all {
		if s.f < 0 && (wanted >= 3 || id == "noshop") {
			continue
		}
		out = append(out, s.r)
	}
	return out
}

// Topic is what a search is about, for the tags on the AI answer.
type Topic struct {
	Label, Icon string
}

var topics = []struct {
	t  Topic
	re *regexp.Regexp
}{
	{Topic{"Code", "code"}, regexp.MustCompile(`(?i)\b(golang|go lang|python|javascript|typescript|rust|kotlin|java|c\+\+|c#|sql|linux|bash|powershell|docker|kubernetes|git|api|compile|error|exception|function|library|framework|regex|json|yaml|npm|pip|cargo|wayland|kernel|nix|fedora|ubuntu|arch|code|programming|algorithm|database|server|cloud|devops|aiops|llm|rag|vector)\b`)},
	{Topic{"Health", "heart"}, regexp.MustCompile(`(?i)\b(symptom|symptoms|disease|pain|doctor|medicine|medication|dose|vitamin|diet|sleep|anxiety|depression|fever|covid|flu|cancer|diabetes|blood|pregnan\w*|health|therapy|injury|salud|dolor)\b`)},
	{Topic{"Science", "lab"}, regexp.MustCompile(`(?i)\b(physics|chemistry|biology|quantum|atom|molecule|planet|galaxy|black hole|evolution|dna|gene|climate|theory|equation|math|mathematics|calculus|statistics|probability|science)\b`)},
	{Topic{"Money", "dollar"}, regexp.MustCompile(`(?i)\b(price|cost|salary|invest|investing|stock|stocks|crypto|bitcoin|bank|loan|tax|taxes|budget|inflation|mortgage|insurance|money|dinero|precio)\b`)},
	{Topic{"How-to", "book"}, regexp.MustCompile(`(?i)^(how (to|do|can)|como|cómo)\b|\b(tutorial|guide|step by step|install|setup|set up|configure|fix)\b`)},
	{Topic{"Travel", "globe"}, regexp.MustCompile(`(?i)\b(flight|flights|hotel|hotels|visa|trip|travel|itinerary|beach|museum|things to do|weather)\b`)},
	{Topic{"Food", "heart"}, regexp.MustCompile(`(?i)\b(recipe|recipes|cook|cooking|bake|baking|restaurant|food|dish|ingredients|receta)\b`)},
	{Topic{"Shopping", "cart"}, buyIntent},
	{Topic{"Entertainment", "gamepad"}, regexp.MustCompile(`(?i)\b(movie|movies|film|series|episode|season|anime|game|games|song|album|lyrics|actor|actress|trailer|netflix|spotify)\b`)},
	{Topic{"Sports", "star"}, regexp.MustCompile(`(?i)\b(football|soccer|nba|nfl|fifa|league|match|score|tennis|baseball|f1|formula 1|olympics)\b`)},
	{Topic{"Definition", "book"}, regexp.MustCompile(`(?i)^(what is|what are|what's|define|meaning of|qué es|que es)\b`)},
}

// TopicOf guesses what query is about ("General" when nothing fits).
func TopicOf(query string) Topic {
	for _, t := range topics {
		if t.re.MatchString(query) {
			return t.t
		}
	}
	return Topic{"General", "sparkle"}
}

// SourceQuality rates the sources of an answer: 2 strong (references, docs,
// research, official), 1 mixed, 0 thin (few or weak sources).
func SourceQuality(src []WebResult, query string) int {
	if len(src) == 0 {
		return 0
	}
	strong, weak := 0, 0
	for _, s := range src {
		t, _ := siteTier(Host(s.URL))
		switch {
		case t.weight >= 1.3:
			strong++
		case t.weight < 0.9:
			weak++
		}
	}
	switch {
	case strong*2 >= len(src) && len(src) >= 3:
		return 2
	case weak*2 > len(src) || len(src) < 2:
		return 0
	}
	return 1
}

// Completeness rates an answer: 2 thorough, 1 a good overview, 0 brief.
func Completeness(r AIResult) int {
	words := len(strings.Fields(r.Text))
	parts := 0
	for _, b := range r.Blocks {
		if b.Kind == "h" || b.Kind == "li" {
			parts++
		}
	}
	switch {
	case words >= 260 && len(r.Sources) >= 4 || words >= 180 && parts >= 4 && len(r.Sources) >= 3:
		return 2
	case words >= 90:
		return 1
	}
	return 0
}
