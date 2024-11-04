const std = @import("std");
const Singletons = @import("./Singletons.zig");
const PublicSuffixDatabase = @import("./PublicSuffixDatabase.zig");

const domain_replacements = std.StaticStringMap([]const u8).initComptime(&.{
    .{ "twitter.com", "fxtwitter.com" },
    .{ "x.com", "fxtwitter.com" },
    // .{ "tiktok.com", "tiktxk.com" }, tiktxk doesn't really work + tiktok seems to have fixed their own embeds
    .{ "instagram.com", "ddinstagram.com" },
    .{ "reddit.com", "rxddit.com" },
});

const domain_filters = std.StaticStringMap(*const fn (std.Uri) bool).initComptime(&.{
    .{ "twitter.com", isLinkToTweet },
    .{ "x.com", isLinkToTweet },
    .{ "instagram.com", isLinkToInstagramPost },
    .{ "reddit.com", isLinkToRedditPost },
});

const iana_only = PublicSuffixDatabase.QueryOptions{ .division_filter = std.EnumSet(PublicSuffixDatabase.Division).initOne(.iana) };

fn BetterUrlsError(comptime Writer: type) type {
    return Writer.Error || std.Uri.ParseError;
}
pub fn betterUrls(string: []const u8, writer: anytype) BetterUrlsError(@TypeOf(writer))!usize {
    var size: usize = 0;
    const urls = getUrls(string).constSlice();
    for (0.., urls) |idx, url| {
        const uri = std.Uri.parse(url) catch |err| {
            std.log.err("{} error parsing url: {s}", .{ err, url });
            return err;
        };
        const host = switch (uri.host orelse continue) {
            inline else => |thing| thing, // don't care if it's encoded or not
        };
        const suffix_db = Singletons.public_suffix_database orelse std.debug.panic("public suffix databse not initialized", .{});
        const site = suffix_db.getPublicSuffixPlusOne(host, iana_only) orelse {
            continue;
        };
        const mapped_site = domain_replacements.get(site) orelse {
            continue;
        };

        if (domain_filters.get(site)) |isValid| {
            if (!isValid(uri)) {
                continue;
            }
        }

        const replacement_start = std.mem.indexOf(u8, url, site) orelse {
            continue;
        };
        const replacement_end = replacement_start + site.len;

        if (idx != 0) {
            try writer.writeByte('\n');
        }
        try writer.writeAll("-# ");
        try writer.writeAll(url[0..replacement_start]);
        try writer.writeAll(mapped_site);
        try writer.writeAll(url[replacement_end..]);
        size += 1;
    }
    return size;
}

// returns the slices inside of `string` which contain urls
fn getUrls(string: []const u8) std.BoundedArray([]const u8, 4) {
    var urls = std.BoundedArray([]const u8, 4){};

    var remaining_str = string;
    while (true) {
        const idx = std.ascii.indexOfIgnoreCase(remaining_str, "https://") orelse std.ascii.indexOfIgnoreCase(remaining_str, "http://") orelse break;
        remaining_str = remaining_str[idx..];

        const url = trimAfterUrl(remaining_str);
        urls.append(url) catch unreachable; // unreachable because we always check capacity after appending
        if (urls.len == urls.capacity()) {
            return urls;
        }

        remaining_str = remaining_str[remaining_str.len..];
    }

    return urls;
}

// trims off everything after the url
fn trimAfterUrl(url: []const u8) []const u8 {
    const until_whitespace = std.mem.trimRight(u8, url, std.ascii.whitespace ++ "<");
    const no_weird_chars_at_end = std.mem.trimRight(u8, until_whitespace, std.ascii.whitespace ++ "<.,:;\"']");

    return no_weird_chars_at_end;
}

fn isLinkToTweet(uri: std.Uri) bool {
    // i don't really care if it's percent-encoded or not
    const path: []const u8 = switch (uri.path) {
        inline else => |str| str,
    };

    var iter = std.mem.splitScalar(u8, path, '/');
    var idx: usize = 0;
    while (iter.next()) |path_part| {
        defer idx += 1; // increment idx after every iteration

        switch (idx) {
            // idx==0 => always empty
            0 => {},
            // idx==1 => user. do not need to validate
            1 => {},
            // idx==2 => must be "status"
            2 => {
                if (!std.ascii.eqlIgnoreCase(path_part, "status")) {
                    return false;
                }
            },
            // idx==3 => tweet id, don't care
            3 => break,
            // else => don't care
            else => break,
        }
    }
    // if the url did not get to the tweet id
    if (idx < 3) {
        return false;
    }

    return true;
}

fn isLinkToInstagramPost(uri: std.Uri) bool {
    // i don't really care if it's percent-encoded or not
    const path: []const u8 = switch (uri.path) {
        inline else => |str| str,
    };

    var iter = std.mem.splitScalar(u8, path, '/');
    var idx: usize = 0;
    while (iter.next()) |path_part| {
        defer idx += 1;

        switch (idx) {
            // idx==0 => always empty
            0 => {},
            // idx==1 => type of post. we care about "reel", "reels", and "p"
            1 => {
                if (std.ascii.startsWithIgnoreCase(path_part, "reel")) {
                    return true;
                }
                if (path_part.len == 1 and path_part[0] == 'p') {
                    return true;
                }
            },
            // idx==2 => post id, i don't care about validating this or anything past it tho.
            2 => {
                break;
            },
            // else => don't care, no more validations
            else => break,
        }
    }
    if (idx < 3) {
        return false;
    }

    return true;
}

fn isLinkToRedditPost(uri: std.Uri) bool {
    // i don't really care if it's percent-encoded or not
    const path: []const u8 = switch (uri.path) {
        inline else => |str| str,
    };

    var contains_post = false;
    var iter = std.mem.splitScalar(u8, path, '/');
    var idx: usize = 0;
    while (iter.next()) |path_part| {
        defer idx += 1;

        switch (idx) {
            // idx==0 => always empty
            0 => {},
            // idx==1 => type of page. (ie /r/, /u/, etc). don't care to validate.
            1 => {},
            // idx==2 => user/subreddit. don't care to validate.
            2 => {},
            // idx==3 => must be "comments" or "s".
            3 => {
                if (path_part.len == 1 and path_part[0] == 's') {
                    contains_post = true;
                }
                if (std.ascii.eqlIgnoreCase(path_part, "comments")) {
                    contains_post = true;
                }
            },
            // idx==4 => post id, don't care to validate this
            4 => {},
            // else => don't care, no more validations
            else => break,
        }
    }

    // must be /<type>/<place>/s|comments/<postid>
    if (idx < 5 or !contains_post) {
        return false;
    }

    return true;
}

test "test url mappings" {
    Singletons.public_suffix_database = PublicSuffixDatabase.stub(std.testing.allocator);
    defer Singletons.deinit(std.testing.allocator);

    const Case = struct { input: []const u8, expected: []const u8 };
    const table = [_]Case{
        .{ .input = "https://example.com", .expected = "" },
        .{ .input = "https://reddit.com", .expected = "" },
        .{ .input = "https://reddit.com/", .expected = "" },
        .{ .input = "https://reddit.com/r/subreddit", .expected = "" },
        .{ .input = "https://www.reddit.com/r/aww/comments/90bu6w/heat_index_was_110_degrees_so_we_offered_him_a/", .expected = "-# https://www.rxddit.com/r/aww/comments/90bu6w/heat_index_was_110_degrees_so_we_offered_him_a/" },
        .{ .input = "https://www.reddit.com/r/aww/s/29898yuaudfh0o97h", .expected = "-# https://www.rxddit.com/r/aww/s/29898yuaudfh0o97h" },
        .{ .input = "https://new.reddit.com/r/aww/s/29898yuaudfh0o97h", .expected = "-# https://new.rxddit.com/r/aww/s/29898yuaudfh0o97h" },
        .{ .input = "https://old.reddit.com/r/aww/s/29898yuaudfh0o97h", .expected = "-# https://old.rxddit.com/r/aww/s/29898yuaudfh0o97h" },
        .{ .input = "https://www.instagram.com/reels/examplexample", .expected = "-# https://www.ddinstagram.com/reels/examplexample" },
        .{ .input = "https://www.instagram.com/reel/examplexample", .expected = "-# https://www.ddinstagram.com/reel/examplexample" },
        .{ .input = "https://www.instagram.com/p/examplexample", .expected = "-# https://www.ddinstagram.com/p/examplexample" },
        .{ .input = "https://instagram.com/reels/examplexample", .expected = "-# https://ddinstagram.com/reels/examplexample" },
        .{ .input = "https://instagram.com/p/examplexample", .expected = "-# https://ddinstagram.com/p/examplexample" },
        .{ .input = "https://x.com/example", .expected = "" },
        .{ .input = "https://twitter.com/example", .expected = "" },
        .{ .input = "https://www.x.com/example", .expected = "" },
        .{ .input = "https://www.twitter.com/example", .expected = "" },
        .{ .input = "https://x.com/example/status/2348570197856", .expected = "-# https://fxtwitter.com/example/status/2348570197856" },
        .{ .input = "https://twitter.com/example/status/2348570197856", .expected = "-# https://fxtwitter.com/example/status/2348570197856" },
        .{ .input = "https://www.x.com/example/status/2348570197856", .expected = "-# https://www.fxtwitter.com/example/status/2348570197856" },
        .{ .input = "https://www.twitter.com/example/status/2348570197856", .expected = "-# https://www.fxtwitter.com/example/status/2348570197856" },
        .{ .input = "https://www.twitter.com/example/with_replies", .expected = "" },
        .{ .input = "https://www.x.com/example/with_replies", .expected = "" },
    };

    for (table) |case| {
        var output = std.BoundedArray(u8, 200){};
        _ = try betterUrls(case.input, output.writer());

        std.testing.expectEqualStrings(case.expected, output.constSlice()) catch |err| {
            std.debug.print("above error occurred while parsing input {s}\n", .{case.input});
            return err;
        };
    }
}
