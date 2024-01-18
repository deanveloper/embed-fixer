package urlmap

import (
	"log/slog"
	"net/url"
	"strings"

	"golang.org/x/net/publicsuffix"
)

// MapURLs maps urls
func MapURLs(domainReplacements map[string]string, domainFilters map[string]func(*url.URL) bool, urls []string) []string {

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

		domainFilter, hasDomainFilter := domainFilters[domain]
		if !hasDomainFilter {
			slog.Error("no domain filter found for domain", slog.String("domain", domain), slog.String("url", parsedURL.Redacted()))
			continue
		}
		if !domainFilter(parsedURL) {
			continue
		}

		mappedURL := strings.Replace(stringURL, domain, mappedDomain, 1)
		if stringURL != mappedURL {
			mappedUrls = append(mappedUrls, mappedURL)
		}
	}

	return mappedUrls
}
