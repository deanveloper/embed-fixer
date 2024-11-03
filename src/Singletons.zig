const std = @import("std");
const deancord = @import("deancord");
const PublicSuffixDatabase = @import("./PublicSuffixDatabase.zig");

pub var public_suffix_database: ?PublicSuffixDatabase = null;

pub fn init(allocator: std.mem.Allocator) !void {
    public_suffix_database = try initPublicSuffixDatabase(allocator);
}

pub fn deinit(allocator: std.mem.Allocator) void {
    if (public_suffix_database) |*db| {
        db.deinit(allocator);
        public_suffix_database = null;
    }
}

fn initPublicSuffixDatabase(allocator: std.mem.Allocator) !PublicSuffixDatabase {
    const max_tries: u8 = 5;
    var tries: u8 = 0;
    var last_error: PublicSuffixDatabase.FetchError = undefined;
    while (tries < max_tries) : (tries += 1) {
        return PublicSuffixDatabase.fetch(allocator) catch |err| {
            last_error = err;
            continue;
        };
    }
    return last_error;
}

test {
    _ = PublicSuffixDatabase;
}
