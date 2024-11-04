const std = @import("std");
const deancord = @import("deancord");
const handlers = @import("./handlers.zig");
const Singletons = @import("./Singletons.zig");

var commands: std.StaticStringMap(fn (*deancord.EndpointClient, deancord.gateway.event_data.receive_events.InteractionCreate) anyerror!void) = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    try Singletons.init(allocator);
    defer Singletons.deinit(allocator);

    const token = std.process.getEnvVarOwned(allocator, "TOKEN") catch |err| {
        switch (err) {
            error.EnvironmentVariableNotFound => {
                std.log.err("environment variable TOKEN is required", .{});
                return;
            },
            else => return err,
        }
    };
    defer allocator.free(token);
    const auth = deancord.Authorization{ .bot = token };

    var endpoint = deancord.EndpointClient.init(allocator, auth);
    defer endpoint.deinit();

    var retry_timer = try std.time.Timer.start();
    var retries: u8 = 0;

    while (true) {
        if (retry_timer.read() > 10 * std.time.ns_per_s) {
            retry_timer.reset();
            retries = 0;
        }

        if (retries > 5) {
            std.log.err("Hit 5 retries within 10 seconds, aborting", .{});
            return;
        }
        startGateway(allocator, &endpoint, token) catch |err| {
            std.log.err("==== UH OH!! ====", .{});
            std.log.err("error returned in gateway: {}", .{err});
            if (@errorReturnTrace()) |trace| {
                std.log.err("{}", .{trace});
            }
        };
    }
}

fn startGateway(allocator: std.mem.Allocator, endpoint: *deancord.EndpointClient, token: []const u8) !void {
    var gateway = try deancord.GatewayClient.initWithRestClient(allocator, endpoint);
    errdefer gateway.deinit();

    const application_id = try initializeBot(&gateway, token);

    _ = try handlers.createFixEmbedCommand(endpoint, application_id);

    while (true) {
        const parsed = gateway.readEvent() catch |err| switch (err) {
            error.EndOfStream, error.ServerClosed => return err,
            else => {
                std.log.err("error occurred while reading gateway event, continuing: {}", .{err});
                continue;
            },
        };
        defer parsed.deinit();

        onGatewayEvent(endpoint, &gateway, application_id, parsed.value);
    }
}

fn initializeBot(
    gateway: *deancord.GatewayClient,
    token: []const u8,
) !deancord.model.Snowflake {
    const ready_parsed = try gateway.authenticate(token, deancord.model.Intents{ .message_content = true, .guild_messages = true });
    defer ready_parsed.deinit();

    const event = ready_parsed.value.d orelse {
        std.log.err("data value of ready event not found", .{});
        return error.BadReadyEvent;
    };
    switch (event) {
        .Ready => |ready| {
            std.log.info("authenticated as user {}", .{ready.user.id});
            return ready.application.id;
        },
        else => |other_event| {
            std.log.err("expected ready event, got {s}", .{@tagName(other_event)});
            return error.BadReadyEvent;
        },
    }
}

fn onGatewayEvent(
    client: *deancord.EndpointClient,
    gateway: *deancord.GatewayClient,
    application_id: deancord.model.Snowflake,
    event: deancord.gateway.ReceiveEvent,
) void {
    _ = gateway;
    _ = application_id;
    switch (event.d orelse return) {
        .MessageCreate => |msg_event| {
            handlers.onMessageCreate(client, msg_event) catch |err| {
                std.log.err("error occurred while calling onMessageCreate: {}", .{err});
                std.log.err("context for error: {}", .{std.json.fmt(msg_event, .{})});
                if (@errorReturnTrace()) |trace| {
                    std.log.err("{}", .{trace});
                }
                return;
            };
        },
        .InteractionCreate => |interaction_event| {
            handlers.onFixEmbedCommand(client, interaction_event) catch |err| {
                std.log.err("error occurred while calling onFixEmbedCommand: {}", .{err});
                std.log.err("context for error: {}", .{std.json.fmt(interaction_event, .{})});
                if (@errorReturnTrace()) |trace| {
                    std.log.err("{}", .{trace});
                }
            };
        },
        else => {
            // ignore
        },
    }
}

test {
    _ = Singletons;
    _ = handlers;
}
