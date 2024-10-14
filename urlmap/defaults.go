package urlmap

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// DomainReplacements is a mapping of domain names to their replacements
var DomainReplacements = map[string]string{
	"twitter.com":   "fxtwitter.com",
	"x.com":         "fxtwitter.com",
	"tiktok.com":    "tiktxk.com",
	"instagram.com": "ddinstagram.com",
	"reddit.com":    "rxddit.com",
}

// DomainFilters is a mapping of domain names to filters for said domain name
var DomainFilters = map[string]func(*url.URL) bool{
	"twitter.com":   isLinkToTweet,
	"x.com":         isLinkToTweet,
	"tiktok.com":    isLinkToTikTokPost,
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
	if len(link.Path) < 1 {
		return false
	}
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

func isLinkToTikTokPost(link *url.URL) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, link.String(), strings.NewReader(""))
	if err != nil {
		slog.Debug("error while requesting to see if tiktxk link is valid", slog.String("site", "tiktok"), slog.String("url", link.Redacted()), slog.Any("err", err))
		return false
	}
	req.Header.Add("User-Agent", "Embed Fixer Bot")

	res, err := http.DefaultTransport.RoundTrip(req)
	if err != nil {
		slog.Debug("error while doing http roundtrip to see if tiktxk link is valid", slog.String("site", "tiktok"), slog.String("url", link.Redacted()), slog.Any("err", err))
		return false
	}
	defer res.Body.Close()

	// only OK (2xx) and REDIRECT (3xx) status codes should be allowed
	if res.StatusCode < 200 || res.StatusCode >= 400 {
		slog.Debug("tiktxk returned an error status code", slog.String("site", "tiktok"), slog.String("url", link.Redacted()), slog.Int("status", res.StatusCode), slog.Any("err", err))
		return false
	}

	jsonDecoder := json.NewDecoder(res.Body)
	var parsedResponse TiktxkResponse
	jsonDecoder.Decode(&parsedResponse)

	return parsedResponse.Success
}

// TiktxkResponse is a struct which describes the success state of a tiktxk response
type TiktxkResponse struct {
	Success bool `json:"success"`
}
