package urlmap

import (
	"log/slog"
	"net/url"
	"strings"
)

var DomainReplacements = map[string]string{
	"twitter.com":   "fxtwitter.com",
	"x.com":         "fxtwitter.com",
	"tiktok.com":    "tiktxk.com",
	"instagram.com": "ddinstagram.com",
	"reddit.com":    "rxddit.com",
}

var DomainFilters = map[string]func(*url.URL) bool{
	"twitter.com":   isLinkToTweet,
	"x.com":         isLinkToTweet,
	"tiktok.com":    func(u *url.URL) bool { return true }, // tiktok post urls vary so much. just allow all of them for now lol
	"instagram.com": isLinkToInstagramPost,
	"reddit.com":    isLinkToRedditPost,
}

// must have a user and numeric tweet id
func isLinkToTweet(link *url.URL) bool {
	split := strings.Split(link.Path[1:], "/")
	if len(split) < 2 {
		slog.Debug("url too short", slog.String("site", "twitter"), slog.String("url", link.Redacted()))
		return false
	}

	// make sure split[1] is a tweet id
	isTweetID := true
	for _, r := range split[1] {
		if r < '0' || '9' < r {
			isTweetID = false
			break
		}
	}

	if isTweetID {
		return true
	}

	// there's probably a lot of cases for this, that's okay
	if split[1] == "with_replies" || split[1] == "media" {
		return false
	}

	slog.Debug("fallback url", slog.String("site", "twitter"), slog.String("url", link.Redacted()), slog.String("tweetid", split[1]))
	return true
}

func isLinkToInstagramPost(link *url.URL) bool {
	split := strings.Split(link.Path[1:], "/")
	if len(split) < 2 {
		slog.Debug("url too short", slog.String("site", "instagram"), slog.String("url", link.Redacted()))
		return false
	}
	if split[0] == "reel" || split[0] == "reels" || split[0] == "p" {
		return true
	}
	// there might be more things to include here, not sure yet...
	slog.Debug("fallback url", slog.String("site", "instagram"), slog.String("url", link.Redacted()), slog.Any("split", split))
	return false
}

func isLinkToRedditPost(link *url.URL) bool {
	split := strings.Split(link.Path[1:], "/")
	if len(split) < 4 {
		slog.Debug("url too short", slog.String("site", "reddit"), slog.String("url", link.Redacted()))
		return false
	}
	if split[2] == "comments" || split[2] == "s" {
		return true
	}
	// there might be more things to include here, not sure yet...
	slog.Debug("fallback url", slog.String("site", "reddit"), slog.String("url", link.Redacted()))
	return false
}
