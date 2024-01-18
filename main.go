package main

import (
	"log/slog"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"syscall"

	"github.com/bwmarrin/discordgo"
	"github.com/deanveloper/embed-fixer/urlmap"
)

var urlSelector = regexp.MustCompile("https?://\\S+\\b")

func main() {
	token, ok := os.LookupEnv("TOKEN")
	if !ok {
		slog.Error("no authentication provided")
		return
	}

	discord, err := discordgo.New("Bot " + token)
	if err != nil {
		slog.Error("error while trying to authenticate", slog.Any("error", err))
		return
	}

	discord.AddHandler(messageCreate)
	discord.Identify.Intents = discordgo.IntentsGuildMessages

	err = discord.Open()
	if err != nil {
		slog.Error("error opening connection", slog.Any("error", err))
		return
	}

	slog.Info("Bot is now running, press CTRL-C to exit.")
	sc := make(chan os.Signal, 1)
	signal.Notify(sc, syscall.SIGINT, syscall.SIGTERM, os.Interrupt)
	<-sc

	// Cleanly close down the Discord session.
	discord.Close()
}

func messageCreate(s *discordgo.Session, m *discordgo.MessageCreate) {
	// ignore own messages
	if m.Author.ID == s.State.User.ID {
		return
	}

	if !strings.Contains(m.Content, "https://") {
		return
	}

	urlsInMessage := urlSelector.FindAllString(m.Content, -1)
	mappedURLs := urlmap.MapURLs(urlmap.DomainReplacements, urlmap.DomainFilters, urlsInMessage)

	// reply
	_, err := s.ChannelMessageSendComplex(m.ChannelID, &discordgo.MessageSend{
		Content:         strings.Join(mappedURLs, " "),
		Reference:       m.Reference(),
		AllowedMentions: &discordgo.MessageAllowedMentions{},
	})
	if err != nil {
		slog.Error("error while sending reply", slog.Any("error", err))
		return
	}

	// remove embeds on original msg
	flags := struct {
		Flags int `json:"flags"`
	}{Flags: int(m.Flags | discordgo.MessageFlagsSuppressEmbeds)}
	channelMessageEndpoint := discordgo.EndpointChannelMessage(m.ChannelID, m.ID)
	_, err = s.Request("PATCH", channelMessageEndpoint, flags)
	if err != nil {
		slog.Error("non-critical error while suppressing embeds", slog.Any("error", err))
	}
}
