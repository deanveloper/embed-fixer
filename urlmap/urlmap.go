package urlmap

import (
	"log/slog"
	"net/url"
	"strings"

	"golang.org/x/net/publicsuffix"
)

// MapURLs maps urls.
//
//   - `domainReplacements` is a map of domains and their replacements
//   - `filters` map of domains to a filter function to filter out only certain requests.
//     The function takes a URL (post-mapping, ie "https://fxtwitter.example/...") and returns true if the URL should be replaced.
func MapURLs(domainReplacements map[string]string, filters map[string]func(*url.URL) bool, urls []string) []string {
	var mappedUrls []string
	for _, stringURL := range urls {
		parsedURL, err := url.Parse(stringURL)
		if err != nil {
			slog.Error("error while parsing url", slog.String("url", stringURL), slog.Any("error", err))
			continue
		}

		domain, err := publicsuffix.EffectiveTLDPlusOne(parsedURL.Host)
		if err != nil {
			slog.Error("error while getting TDL+1 for url", slog.String("url", parsedURL.Redacted()), slog.Any("error", err))
			continue
		}

		mappedDomain, ok := domainReplacements[domain]
		if !ok {
			continue
		}

		stringMappedURL := strings.Replace(stringURL, domain, mappedDomain, 1)
		parsedMappedURL, err := url.Parse(stringMappedURL)
		if err != nil {
			slog.Error("error while parsing mapped url", slog.String("url", parsedURL.Redacted()), slog.String("mappedURL", stringMappedURL), slog.Any("error", err))
			continue
		}

		domainFilter, hasDomainFilter := filters[domain]
		if !hasDomainFilter {
			slog.Error("no domain filter found for domain", slog.String("domain", domain), slog.String("url", parsedURL.Redacted()))
			continue
		}
		if !domainFilter(parsedMappedURL) {
			continue
		}
		if stringURL != stringMappedURL {
			mappedUrls = append(mappedUrls, stringMappedURL)
		}
	}

	return mappedUrls
}
