package main

import (
	"log"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"syscall"

	"github.com/bwmarrin/discordgo"
)

var urlSelector = regexp.MustCompile("https?://\\S+\\b")

var urlReplacer = strings.NewReplacer(
	// twitter
	"https://twitter.com/", "https://fxtwitter.com/",
	"https://www.twitter.com/", "https://www.fxtwitter.com/",
	"https://x.com/", "https://fxtwitter.com/",
	"https://www.x.com/", "https://www.fxtwitter.com/",

	// tiktok
	"https://tiktok.com/", "https://tiktxk.com/",
	"https://www.tiktok.com/", "https://www.tiktxk.com/",
	"https://vt.tiktok.com/", "https://vt.tiktxk.com/",

	// instagram
	"https://instagram.com", "https://ddinstagram.com/",
	"https://www.instagram.com", "https://www.ddinstagram.com/",

	// reddit
	"https://reddit.com", "https://rxddit.com/",
	"https://www.reddit.com", "https://www.rxddit.com/",
	"https://new.reddit.com", "https://new.rxddit.com/",
	"https://old.reddit.com", "https://old.rxddit.com/",
)

func main() {
	token, ok := os.LookupEnv("TOKEN")
	if !ok {
		log.Println("no authentication provided")
		return
	}

	discord, err := discordgo.New("Bot " + token)
	if err != nil {
		log.Printf("error while trying to authenticate: %s\n", err)
		return
	}

	discord.AddHandler(messageCreate)
	discord.Identify.Intents = discordgo.IntentsGuildMessages
	discord.Debug = true

	err = discord.Open()
	if err != nil {
		log.Println("error opening connection,", err)
		return
	}

	log.Println("Bot is now running, press CTRL-C to exit.")
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

	var urlsInMessage = urlSelector.FindAllString(m.Content, -1)

	var mappedUrls []string
	for _, url := range urlsInMessage {
		mappedURL := urlReplacer.Replace(url)
		if url != mappedURL {
			mappedUrls = append(mappedUrls, mappedURL)
		}
	}

	// reply
	_, err := s.ChannelMessageSendComplex(m.ChannelID, &discordgo.MessageSend{
		Content:         strings.Join(mappedUrls, " "),
		Reference:       m.Reference(),
		AllowedMentions: &discordgo.MessageAllowedMentions{},
	})
	if err != nil {
		log.Printf("error while sending reply: %s\n", err)
		return
	}

	// remove embeds on original msg
	flags := struct {
		Flags int `json:"flags"`
	}{Flags: int(m.Flags | discordgo.MessageFlagsSuppressEmbeds)}
	channelMessageEndpoint := discordgo.EndpointChannelMessage(m.ChannelID, m.ID)
	_, err = s.Request("PATCH", channelMessageEndpoint, flags)
	if err != nil {
		log.Printf("non-critical error while suppressing embeds: %s\n", err)
	}
}
