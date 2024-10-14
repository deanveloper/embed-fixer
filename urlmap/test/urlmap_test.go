package urlmap_test

import (
	"log/slog"
	"maps"
	"net/url"
	"os"
	"slices"
	"testing"

	"github.com/deanveloper/embed-fixer/urlmap"
)

func TestMapURLsWithDefaults(t *testing.T) {

	// override tiktok's domain filter because it performs REST requests and that's not gouda
	var testableDomainFilters = maps.Clone(urlmap.DomainFilters)
	testableDomainFilters["tiktok.com"] = func(u *url.URL) bool { return true }

	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelDebug})))
	actual := urlmap.MapURLs(urlmap.DomainReplacements, testableDomainFilters, []string{
		"https://example.com",
		"https://reddit.com",
		"https://reddit.com/",
		"https://reddit.com/r/subreddit",
		"https://www.reddit.com/r/aww/comments/90bu6w/heat_index_was_110_degrees_so_we_offered_him_a/",
		"https://www.reddit.com/r/aww/s/29898yuaudfh0o97h",
		"https://new.reddit.com/r/aww/s/29898yuaudfh0o97h",
		"https://old.reddit.com/r/aww/s/29898yuaudfh0o97h",
		"https://tiktok.com/@example/exAmPlE/",
		"https://www.tiktok.com/@example/exAmPlE/",
		"https://vm.tiktok.com/exAmPlE/",
		"https://vt.tiktok.com/exAmPlE/",
		"https://www.instagram.com/reels/examplexample",
		"https://www.instagram.com/reel/examplexample",
		"https://www.instagram.com/p/examplexample",
		"https://instagram.com/reels/examplexample",
		"https://www.instagram.com/p/examplexample",
		"https://x.com/example",
		"https://twitter.com/example",
		"https://www.x.com/example",
		"https://www.twitter.com/example",
		"https://x.com/example/2348570197856",
		"https://twitter.com/example/2348570197856",
		"https://www.x.com/example/2348570197856",
		"https://www.twitter.com/example/2348570197856",
		"https://www.twitter.com/example/with_replies",
		"https://www.x.com/example/with_replies",
	})

	expected := []string{
		"https://www.rxddit.com/r/aww/comments/90bu6w/heat_index_was_110_degrees_so_we_offered_him_a/",
		"https://www.rxddit.com/r/aww/s/29898yuaudfh0o97h",
		"https://new.rxddit.com/r/aww/s/29898yuaudfh0o97h",
		"https://old.rxddit.com/r/aww/s/29898yuaudfh0o97h",
		"https://tiktxk.com/@example/exAmPlE/",
		"https://www.tiktxk.com/@example/exAmPlE/",
		"https://vm.tiktxk.com/exAmPlE/",
		"https://vt.tiktxk.com/exAmPlE/",
		"https://www.ddinstagram.com/reels/examplexample",
		"https://www.ddinstagram.com/reel/examplexample",
		"https://www.ddinstagram.com/p/examplexample",
		"https://ddinstagram.com/reels/examplexample",
		"https://www.ddinstagram.com/p/examplexample",
		"https://fxtwitter.com/example/2348570197856",
		"https://fxtwitter.com/example/2348570197856",
		"https://www.fxtwitter.com/example/2348570197856",
		"https://www.fxtwitter.com/example/2348570197856",
	}

	if !slices.Equal(expected, actual) {
		t.Errorf("values which are expected but not present:")
		for _, value := range difference(expected, actual) {
			t.Logf("    %v", value)
		}
		t.Errorf("values which are present but not expected")
		for _, value := range difference(actual, expected) {
			t.Logf("    %v", value)
		}
	}
}

// from https://stackoverflow.com/a/45428032
func difference(a, b []string) []string {
	mb := make(map[string]struct{}, len(b))
	for _, x := range b {
		mb[x] = struct{}{}
	}
	var diff []string
	for _, x := range a {
		if _, found := mb[x]; !found {
			diff = append(diff, x)
		}
	}
	return diff
}
