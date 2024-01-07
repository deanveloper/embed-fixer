package main

import (
	"log"
	"os"
	"os/signal"
	"regexp"
	"slices"
	"strings"
	"syscall"

	"github.com/bwmarrin/discordgo"
)

var urlSelector = regexp.MustCompile("https?://\\S+\\b")

var urlReplacer = strings.NewReplacer(
	"twitter.com", "fxtwitter.com",
	"x.com", "fxtwitter.com",
	"tiktok.com", "tiktxk.com",
	"instagram.com", "ddinstagram.com",
	"reddit.com", "rxddit.com",
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

	_, err := s.ChannelMessageSendReply(m.ChannelID, strings.Join(mappedUrls, " "), m.Reference())
	if err != nil {
		log.Printf("error while sending reply: %s\n", err)
		return
	}

	// suppress embeds
	messageEdit := discordgo.NewMessageEdit(m.ChannelID, m.ID)
	messageEdit.SetContent(m.Content)
	messageEdit.SetEmbeds(slices.Clone(m.Embeds))
	messageEdit.Flags = m.Flags | discordgo.MessageFlagsSuppressEmbeds
	_, err = s.ChannelMessageEditComplex(messageEdit)
	if err != nil {
		log.Printf("non-critical error while suppressing embeds: %s\n", err)
	}
}
