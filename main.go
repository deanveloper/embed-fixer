package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"regexp"
	"slices"
	"strconv"
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

	session, err := discordgo.New("Bot " + token)
	if err != nil {
		slog.Error("error while trying to authenticate", slog.Any("error", err))
		return
	}

	session.AddHandler(messageCreate)
	session.AddHandler(interaction)
	session.Identify.Intents = discordgo.IntentsGuildMessages

	err = session.Open()
	if err != nil {
		slog.Error("error opening connection", slog.Any("error", err))
		return
	}

	initInteractions(session)
	defer destroyInteractions(session)

	slog.Info("Bot is now running, press CTRL-C to exit.")
	sc := make(chan os.Signal, 1)
	signal.Notify(sc, syscall.SIGINT, syscall.SIGTERM, os.Interrupt)
	<-sc

	// Cleanly close down the Discord session.
	session.Close()
}

var registeredInteractions = make(map[string]*discordgo.ApplicationCommand)

func initInteractions(s *discordgo.Session) {
	response, err := s.Request("POST", discordgo.EndpointApplicationGlobalCommands(s.State.Application.ID), FixEmbedCommand{
		Name:             "fix-embed",
		Type:             discordgo.MessageApplicationCommand,
		IntegrationTypes: []IntegrationType{IntegrationTypeGuildInstall, IntegrationTypeUserInstall},
		Contexts:         []InteractionContext{InteractionContextGuild, InteractionContextBotDM, InteractionContextPrivateChannel},
	}, func(cfg *discordgo.RequestConfig) {
		bodyReader := cfg.Request.Body

		body, err := io.ReadAll(bodyReader)
		if err != nil {
			slog.Error("error while debug printing", slog.Any("error", err))
			return
		}
		slog.Debug("request", slog.String("body", string(body)))

		cfg.Request.Body = io.NopCloser(bytes.NewReader(body))
	})
	if err != nil {
		slog.Error("error while initializing interactions", slog.String("interactionName", "fix-embed"), slog.Any("error", err))
		return
	}
	slog.Debug("response", slog.String("body", string(response)))

	var fixEmbedApplicationCommand discordgo.ApplicationCommand
	err = json.Unmarshal(response, &fixEmbedApplicationCommand)
	if err != nil {
		slog.Error("error while parsing global command create response", slog.String("interactionName", "fix-embed"), slog.Any("error", err))
	} else {
		registeredInteractions[fixEmbedApplicationCommand.ID] = &fixEmbedApplicationCommand
	}

	slog.Info("Successfully created interactions")
}

func destroyInteractions(s *discordgo.Session) {
	err := s.ApplicationCommandDelete(s.State.Application.ID, "", "")
	if err != nil {
		slog.Error("error while cleaning up interactions", slog.Any("error", err))
	}
	slog.Info("Successfully cleaned up interactions")
}

func interaction(s *discordgo.Session, i *discordgo.InteractionCreate) {
	if i.Type != discordgo.InteractionApplicationCommand {
		slog.Error("unknown interaction received", slog.Any("interaction", i))
		err := s.InteractionRespond(i.Interaction, &discordgo.InteractionResponse{
			Type: discordgo.InteractionResponseChannelMessageWithSource,
			Data: &discordgo.InteractionResponseData{
				Content: "i only know how to respond to application commands",
				Flags:   discordgo.MessageFlagsEphemeral,
			},
		})
		if err != nil {
			slog.Error("error while responding to unknown interaction", slog.Any("error", err))
			return
		}
		return
	}

	interactionData := i.ApplicationCommandData()
	if _, ok := registeredInteractions[interactionData.ID]; !ok {
		slog.Error("unknown application command received", slog.Any("interaction", i))
		err := s.InteractionRespond(i.Interaction, &discordgo.InteractionResponse{
			Type: discordgo.InteractionResponseChannelMessageWithSource,
			Data: &discordgo.InteractionResponseData{
				Content: "invalid application command",
				Flags:   discordgo.MessageFlagsEphemeral,
			},
		})
		if err != nil {
			slog.Error("error while responding to unknown application command", slog.Any("error", err))
			return
		}
		return
	}

	linksToOriginalMsgs := messageLinks(i.GuildID, interactionData.Resolved.Messages)
	messages := messageContents(interactionData.Resolved.Messages)
	if len(messages) < 1 {
		slog.Error("unknown interaction received", slog.Any("interaction", i))
		s.InteractionRespond(i.Interaction, &discordgo.InteractionResponse{
			Type: discordgo.InteractionResponseChannelMessageWithSource,
			Data: &discordgo.InteractionResponseData{
				Content: "i only know how to respond to message commands right now",
				Flags:   discordgo.MessageFlagsEphemeral,
			},
		})
		return
	}

	if !strings.Contains(messages, "https://") {
		return
	}

	urlsInMessage := urlSelector.FindAllString(messages, -1)
	mappedURLs := urlmap.MapURLs(urlmap.DomainReplacements, urlmap.DomainFilters, urlsInMessage)

	if len(mappedURLs) == 0 {
		err := s.InteractionRespond(i.Interaction, &discordgo.InteractionResponse{
			Type: discordgo.InteractionResponseChannelMessageWithSource,
			Data: &discordgo.InteractionResponseData{
				Content:         "No fixable URLs found in " + linksToOriginalMsgs,
				AllowedMentions: &discordgo.MessageAllowedMentions{},
				Flags:           discordgo.MessageFlagsEphemeral,
			},
		})
		if err != nil {
			slog.Error("error occurred while responding to interaction with no fixable URLs", slog.Any("mappedURLs", mappedURLs), slog.Any("interaction", i))
			return
		}
		return
	}

	fullMessage := "Fixing embeds for " + linksToOriginalMsgs + "\n" + strings.Join(mappedURLs, "\n")

	err := s.InteractionRespond(i.Interaction, &discordgo.InteractionResponse{
		Type: discordgo.InteractionResponseChannelMessageWithSource,
		Data: &discordgo.InteractionResponseData{
			Content:         fullMessage,
			AllowedMentions: &discordgo.MessageAllowedMentions{},
		},
	})
	if err != nil {
		slog.Error("error occurred while responding to interaction", slog.Any("mappedURLs", mappedURLs), slog.Any("interaction", i))
		return
	}
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

	if len(mappedURLs) == 0 {
		return
	}

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

// FixEmbedCommand is a structure that has the stuff required for the Fix Embed command
type FixEmbedCommand struct {
	Name             string                           `json:"name"`
	Type             discordgo.ApplicationCommandType `json:"type"`
	IntegrationTypes []IntegrationType                `json:"integration_types,omitempty"`
	Contexts         []InteractionContext             `json:"contexts,omitempty"`
}

// IntegrationType represents where this app can be installed
type IntegrationType int32

const (
	// IntegrationTypeGuildInstall means an integration which can be installed to a guild
	IntegrationTypeGuildInstall IntegrationType = iota
	// IntegrationTypeUserInstall means an integration which can be installed to a user
	IntegrationTypeUserInstall
)

// InteractionContext is where an interaction can be used, or where it was triggered from
type InteractionContext int32

const (
	// InteractionContextGuild means this interaction can be used within servers
	InteractionContextGuild InteractionContext = iota
	// InteractionContextBotDM means this interaction can be used within DMs with the app's bot user
	InteractionContextBotDM
	// InteractionContextPrivateChannel means this interaction can be used within Group DMs and DMs other than the app's bot user
	InteractionContextPrivateChannel
)

func ptr[T any](t T) *T {
	return &t
}

func messageLinks(guildID string, msgs map[string]*discordgo.Message) string {
	var msgIDs []uint64
	for msgID := range msgs {
		asInt, err := strconv.ParseUint(msgID, 10, 64)
		if err != nil {
			slog.Error("Error parsing into a uint64", slog.String("msgId", msgID))
			continue
		}
		msgIDs = append(msgIDs, asInt)
	}
	slices.Sort(msgIDs)

	allMsgs := ""
	for _, msgID := range msgIDs {
		msgIDStr := strconv.FormatUint(msgID, 10)
		msg := msgs[msgIDStr]
		allMsgs += messageLink(guildID, msg.ChannelID, msg.ID) + " "
	}
	return allMsgs
}

func messageContents(msgs map[string]*discordgo.Message) string {
	var msgIDs []uint64
	for msgID := range msgs {
		asInt, err := strconv.ParseUint(msgID, 10, 64)
		if err != nil {
			slog.Error("Error parsing into a uint64", slog.String("msgId", msgID))
			continue
		}
		msgIDs = append(msgIDs, asInt)
	}
	slices.Sort(msgIDs)

	allMsgs := ""
	for _, msgID := range msgIDs {
		msgIDStr := strconv.FormatUint(msgID, 10)
		allMsgs += msgs[msgIDStr].Content + " "
	}
	return allMsgs
}

// https://discord.com/channels/<guildID>/<channelID>/<messageID>, guildID is '@me' for DMs
func messageLink(guildID, channelID, messageID string) string {
	if guildID == "" {
		guildID = "@me"
	}
	return fmt.Sprintf("https://discord.com/channels/%s/%s/%s", guildID, channelID, messageID)
}
