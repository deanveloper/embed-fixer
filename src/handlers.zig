const std = @import("std");
const deancord = @import("deancord");
const urls = @import("./urls.zig");

pub fn onMessageCreate(client: *deancord.EndpointClient, event: deancord.gateway.event_data.receive_events.MessageCreate) !void {
    if (std.mem.containsAtLeast(u8, event.message.content, 2, "||")) {
        // do nothing if there are spoilers
        return;
    }

    var response_content = std.BoundedArray(u8, 2048){};
    const replacements = try urls.betterUrls(event.message.content, response_content.writer());

    if (replacements == 0) {
        return;
    }

    const create_msg_resp = client.createMessage(event.message.channel_id, deancord.rest.endpoints.CreateMessageFormBody{
        .content = response_content.constSlice(),
        .message_reference = .{
            .channel_id = .{ .some = event.message.channel_id },
            .guild_id = event.guild_id,
            .message_id = .{ .some = event.message.id },
            .fail_if_not_exists = .{ .some = false },
        },
        .allowed_mentions = deancord.model.Message.AllowedMentions{ .parse = &.{}, .replied_user = false, .roles = &.{}, .users = &.{} },
    }) catch |err| {
        std.log.err("critical error when creating message: {}", .{err});
        if (@errorReturnTrace()) |trace| {
            std.log.err("{}", .{trace});
        }
        return err;
    };
    defer create_msg_resp.deinit();
    switch (create_msg_resp.value()) {
        .ok => {},
        .err => |discorderr| {
            std.log.err("unable to send reply: {}", .{std.json.fmt(discorderr, .{})});
            return error.DiscordError;
        },
    }

    // try to remove embeds on original message
    const remove_embed_resp = client.editMessage(event.message.channel_id, event.message.id, deancord.rest.endpoints.EditMessageFormBody{
        .flags = deancord.model.Message.Flags{ .suppress_embeds = true },
    }) catch |err| {
        std.log.err("critical error when suppressing embeds: {}", .{err});
        return err;
    };
    defer remove_embed_resp.deinit();
    switch (remove_embed_resp.value()) {
        .ok => {},
        .err => |discorderr| {
            std.log.warn("discord error when suppressing embeds: {}", .{std.json.fmt(discorderr, .{})});
        },
    }
}

pub fn onFixEmbedCommand(
    client: *deancord.EndpointClient,
    event: deancord.gateway.event_data.receive_events.InteractionCreate,
) !void {
    const event_data = event.data.asSome() orelse return error.BadEvent;
    const application_command = switch (event_data) {
        .application_command => |cmd| cmd,
        else => return error.BadEvent,
    };

    const target_msg_id = application_command.target_id.asSome() orelse return error.NoTarget;
    var target_msg_id_str = std.BoundedArray(u8, 50){};
    try target_msg_id_str.writer().print("{s}", .{target_msg_id});
    const resolved_data = application_command.resolved.asSome() orelse return error.TargetNotResolved;
    const resolved_msgs = resolved_data.messages.asSome() orelse return error.TargetNotResolved;
    const target_msg: deancord.model.Message = resolved_msgs.map.get(target_msg_id_str.constSlice()) orelse return error.TargetNotResolved;

    if (std.mem.containsAtLeast(u8, target_msg.content, 2, "||")) {
        // do nothing if there are spoilers
        return;
    }

    var response_content = std.BoundedArray(u8, 2048){};
    try response_content.writer().print("Fixing messages for {s}\n", .{fmtMessageLink(application_command.guild_id.asSome(), target_msg.channel_id, target_msg.id)});
    const replacements = try urls.betterUrls(target_msg.content, response_content.writer());

    if (replacements == 0) {
        response_content = .{}; // start response content from scratch
        try response_content.writer().print("No fixable URLs found in {s}", .{fmtMessageLink(application_command.guild_id.asSome(), target_msg.channel_id, target_msg.id)});

        const interaction_response = try client.createInteractionResponse(event.id, event.token, deancord.model.interaction.InteractionResponse{
            .type = .channel_message_with_source,
            .data = .{ .some = .{
                .content = .{ .some = response_content.constSlice() },
                .allowed_mentions = .{ .some = deancord.model.Message.AllowedMentions{ .parse = &.{}, .replied_user = false, .roles = &.{}, .users = &.{} } },
                .flags = .{ .some = deancord.model.Message.Flags{ .ephemeral = true } },
            } },
        });
        switch (interaction_response.value()) {
            .ok => {},
            .err => |discorderr| {
                std.log.err("unable to respond to interaction: {}", .{std.json.fmt(discorderr, .{})});
                return error.DiscordError;
            },
        }
        return;
    }

    const interaction_response = try client.createInteractionResponse(event.id, event.token, deancord.model.interaction.InteractionResponse{
        .type = .channel_message_with_source,
        .data = .{ .some = .{
            .content = .{ .some = response_content.constSlice() },
            .allowed_mentions = .{ .some = deancord.model.Message.AllowedMentions{ .parse = &.{}, .replied_user = false, .roles = &.{}, .users = &.{} } },
        } },
    });
    switch (interaction_response.value()) {
        .ok => {},
        .err => |discorderr| {
            std.log.err("unable to respond to interaction: {}", .{std.json.fmt(discorderr, .{})});
            return error.DiscordError;
        },
    }
}

pub fn createFixEmbedCommand(client: *deancord.EndpointClient, application_id: deancord.model.Snowflake) !deancord.model.Snowflake {
    const result = try client.createGlobalApplicationCommand(application_id, deancord.rest.EndpointClient.CreateGlobalApplicationCommandBody{
        .name = "fix embeds",
        .type = .{ .some = .message },
        .contexts = .{ .some = &.{ .bot_dm, .guild, .private_channel } },
        .integration_types = .{ .some = &.{ .guild_install, .user_install } },
    });

    defer result.deinit();
    switch (result.value()) {
        .ok => |command| {
            return command.id;
        },
        .err => |err| {
            std.log.err("error creating `fix embed` command: {}", .{std.json.fmt(err, .{})});
            return error.DiscordError;
        },
    }
}

pub fn destroyAllCommands(client: *deancord.EndpointClient, application_id: deancord.model.Snowflake) void {
    const get_cmds_result = client.getGlobalApplicationCommands(application_id, null) catch |err| {
        std.log.err("error while listing commands: {}", .{err});
        return;
    };
    defer get_cmds_result.deinit();
    const commands = switch (get_cmds_result.value()) {
        .ok => |cmds| cmds,
        .err => |err| {
            std.log.err("error from discord while listing commands: {}", .{err});
            return;
        },
    };

    for (commands) |command| {
        std.log.info("destroying command '{s}'", .{command.name});
        const delete_cmd_result = client.deleteGlobalApplicationCommand(application_id, command.id) catch |err| {
            std.log.err("error deleting command '{s}': {}", .{ command.name, err });
            return;
        };
        switch (delete_cmd_result.value()) {
            .ok => {},
            .err => |err| {
                std.log.err("error from discord while deleting command '{s}': {}", .{ command.name, err });
                return;
            },
        }
    }
}

pub fn destroyCommand(client: *deancord.EndpointClient, application_id: deancord.model.Snowflake, command_id: deancord.model.Snowflake) void {
    const result = client.deleteGlobalApplicationCommand(application_id, command_id) catch |err| {
        std.log.err("error deleting `fix embed` command when calling endpoint: {}", .{err});
        return;
    };
    defer result.deinit();
    switch (result.value()) {
        .ok => {},
        .err => |err| {
            std.log.err("error deleting `fix embed` command when parsing result: {}", .{std.json.fmt(err, .{})});
        },
    }
}

const MessageLinkData = struct {
    guild_id: ?deancord.model.Snowflake,
    channel_id: deancord.model.Snowflake,
    message_id: deancord.model.Snowflake,
};

fn messageLinkFormatter(
    data: MessageLinkData,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    if (data.guild_id) |guild_id| {
        try writer.print("https://discord.com/channels/{s}/{s}/{s}", .{ guild_id, data.channel_id, data.message_id });
    } else {
        try writer.print("https://discord.com/channels/@me/{s}/{s}", .{ data.channel_id, data.message_id });
    }
}

const MessageLinkFormatter = std.fmt.Formatter(messageLinkFormatter);
fn fmtMessageLink(
    guild_id: ?deancord.model.Snowflake,
    channel_id: deancord.model.Snowflake,
    message_id: deancord.model.Snowflake,
) MessageLinkFormatter {
    return MessageLinkFormatter{ .data = MessageLinkData{ .guild_id = guild_id, .channel_id = channel_id, .message_id = message_id } };
}

test {
    _ = urls;
}
