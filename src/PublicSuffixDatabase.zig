const std = @import("std");
const PublicSuffixDatabase = @This();
const punycode = @import("./punycode.zig");
const builtin = @import("std").builtin;

// TODO - move to its own repo and module

rules: std.ArrayListUnmanaged(Rule),

pub const FetchError = std.http.Client.RequestError || std.http.Client.Request.SendError || std.http.Client.Request.WaitError || ParseError;

const uri = std.Uri.parse("https://publicsuffix.org/list/public_suffix_list.dat") catch unreachable;

pub fn fetch(allocator: std.mem.Allocator) FetchError!PublicSuffixDatabase {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var server_header_buffer: [2048]u8 = undefined;

    var request = try client.open(.GET, uri, .{ .server_header_buffer = &server_header_buffer });
    defer request.deinit();
    try request.send();
    try request.wait();

    return try parse(allocator, request.reader());
}

pub const ParseError = std.mem.Allocator.Error || error{ReadError};

pub fn parse(allocator: std.mem.Allocator, reader: anytype) !PublicSuffixDatabase {
    var rules = try std.ArrayListUnmanaged(Rule).initCapacity(allocator, 256);
    var buffered_reader = std.io.bufferedReader(reader);

    var division: ?Division = null;

    while (true) {
        var line = std.BoundedArray(u8, 500){};
        buffered_reader.reader().streamUntilDelimiter(line.writer(), '\n', 500) catch |err| {
            switch (err) {
                error.StreamTooLong => continue,
                error.EndOfStream => {
                    if (line.len == 0) {
                        break;
                    }
                },
                else => return error.ReadError,
            }
        };

        // The list is a set of rules, with one rule per line. Each line is only read up to the first whitespace.
        const whitespace_idx = std.mem.indexOfAny(u8, line.constSlice(), &std.ascii.whitespace) orelse line.len;
        const rule_str = line.constSlice()[0..whitespace_idx];

        // Each line which is not entirely whitespace or begins with a comment contains a rule.
        if (rule_str.len == 0 or std.mem.startsWith(u8, rule_str, "//")) {
            if (std.mem.eql(u8, line.constSlice(), "// ===BEGIN ICANN DOMAINS===") or std.mem.eql(u8, line.constSlice(), "// ===BEGIN IANA DOMAINS===")) {
                division = .iana;
            }
            if (std.mem.eql(u8, line.constSlice(), "// ===END ICANN DOMAINS===") or std.mem.eql(u8, line.constSlice(), "// ===END IANA DOMAINS===")) {
                division = null;
            }
            if (std.mem.eql(u8, line.constSlice(), "// ===BEGIN PRIVATE DOMAINS===")) {
                division = .private;
            }
            if (std.mem.eql(u8, line.constSlice(), "// ===END PRIVATE DOMAINS===")) {
                division = null;
            }

            continue;
        }

        const rule_str_copy = try allocator.dupe(u8, rule_str);
        const rule = Rule.init(rule_str_copy, division);

        try rules.append(allocator, rule);
    }

    return PublicSuffixDatabase{ .rules = rules };
}

pub fn stub(allocator: std.mem.Allocator) PublicSuffixDatabase {
    const string =
        \\// ===BEGIN ICANN DOMAINS===
        \\com
        \\// ===END ICANN DOMAINS===
    ;
    var stream = std.io.fixedBufferStream(string);
    return PublicSuffixDatabase.parse(allocator, stream.reader()) catch unreachable;
}

pub fn deinit(self: *PublicSuffixDatabase, allocator: std.mem.Allocator) void {
    for (self.rules.items) |rule| {
        allocator.free(rule.raw_rule_text);
    }
    self.rules.deinit(allocator);
}

pub fn evaluate(self: PublicSuffixDatabase, domain: []const u8, options: QueryOptions) ?Rule {
    var most_labels_rule: ?Rule = null;
    for (self.rules.items) |rule| {
        if (options.division_filter) |filter| {
            if (!filter.contains(rule.division orelse continue)) {
                continue;
            }
        }

        if (rule.matches(domain)) {
            if (rule.type == .exception) {
                return rule;
            }

            if (most_labels_rule) |most| {
                if (rule.labels > most.labels) {
                    most_labels_rule = rule;
                }
            } else {
                most_labels_rule = rule;
            }
        }
    }

    return most_labels_rule;
}

/// returns the "public suffix plus one" of a domain.
///
/// As an example, for "www.subdomain.example.com", the "public suffix" is "com", but for "www.subdomain.example.co.uk", the "public suffix" is "co.uk".
/// If no public suffix rules match the given domain, null is returned.
pub fn getPublicSuffix(self: PublicSuffixDatabase, domain: []const u8, options: QueryOptions) ?[]const u8 {
    if (self.evaluate(domain, options)) |rule| {
        return getLabels(domain, rule.getSuffixLabelCount());
    } else {
        return null;
    }
}

/// returns the "public suffix plus one" of a domain.
///
/// As an example, for "www.subdomain.example.com", the "public suffix plus one" is "example.com",
/// but for "www.subdomain.example.co.uk", the "public suffix plus one" is "example.co.uk".
/// If no public suffix rules match the given domain, or if there is no additional label past the public suffix (ie, `domain` is set to `co.uk`), null is returned.
pub fn getPublicSuffixPlusOne(self: PublicSuffixDatabase, domain: []const u8, options: QueryOptions) ?[]const u8 {
    if (self.evaluate(domain, options)) |rule| {
        return getLabels(domain, rule.getSuffixLabelCount() + 1);
    } else {
        return null;
    }
}

pub fn format(self: PublicSuffixDatabase, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    var first = true;
    try writer.writeByte('[');
    for (self.rules.items) |rule| {
        try writer.writeAll(rule.raw_rule_text);

        if (!first) {
            try writer.writeByte(',');
        } else {
            first = false;
        }
    }
    try writer.writeByte(']');
}

fn getLabels(domain: []const u8, labels_to_keep: usize) ?[]const u8 {
    var index = domain.len - 1;
    var labels: usize = 1;
    while (true) : (index -= 1) {
        if (domain[index] == '.') {
            if (labels == labels_to_keep) {
                return domain[index + 1 ..];
            }
            labels += 1;
        }
        if (index == 0) {
            if (labels == labels_to_keep) {
                return domain;
            } else {
                return null;
            }
        }
    }
}

pub const Rule = struct {
    division: ?Division,
    type: Type,
    rule_text: []const u8,
    raw_rule_text: []const u8,
    labels: usize,

    pub const Type = enum {
        standard,
        wildcard,
        exception,
    };

    pub fn init(raw_rule_text: []const u8, division: ?Division) Rule {
        if (raw_rule_text.len > 0 and raw_rule_text[0] == '!') {
            return Rule{
                .division = division,
                .type = .exception,
                .rule_text = raw_rule_text[1..],
                .raw_rule_text = raw_rule_text,
                .labels = std.mem.count(u8, raw_rule_text, ".") + 1,
            };
        }
        if (raw_rule_text.len > 1 and raw_rule_text[0] == '*' and raw_rule_text[1] == '.') {
            return Rule{
                .division = division,
                .type = .wildcard,
                .rule_text = raw_rule_text,
                .raw_rule_text = raw_rule_text,
                .labels = std.mem.count(u8, raw_rule_text, ".") + 1,
            };
        }
        return Rule{
            .division = division,
            .type = .standard,
            .rule_text = raw_rule_text,
            .raw_rule_text = raw_rule_text,
            .labels = std.mem.count(u8, raw_rule_text, ".") + 1,
        };
    }

    pub fn getSuffixLabelCount(self: Rule) usize {
        const suffix_label_count = switch (self.type) {
            .standard => self.labels,
            .wildcard => self.labels,
            .exception => self.labels - 1,
        };
        return suffix_label_count;
    }

    pub fn labelIter(self: Rule) LabelIterator {
        return LabelIterator{
            .remaining_rule = self.rule_text,
        };
    }

    pub fn matches(self: Rule, domain: []const u8) bool {

        // max length of a domain label is 63 bytes, 1024 should be more than enough
        var buf: [1024]u8 = undefined;
        var bufalloc = std.heap.FixedBufferAllocator.init(&buf);

        var rule_labels = self.labelIter();
        var domain_labels = LabelIterator{ .remaining_rule = domain };

        while (true) {
            bufalloc.reset();

            if (domain_labels.next()) |domain_label| {
                if (rule_labels.next()) |rule_label| {
                    if (rule_label.len == 1 and rule_label[0] == '*') {
                        return true;
                    }

                    var domain_label_puny = std.ArrayList(u8).init(bufalloc.allocator());
                    var rule_label_puny = std.ArrayList(u8).init(bufalloc.allocator());

                    punycode.encode(domain_label, domain_label_puny.writer()) catch return false;
                    punycode.encode(rule_label, rule_label_puny.writer()) catch return false;

                    if (!std.mem.eql(u8, domain_label_puny.items, rule_label_puny.items)) {
                        return false;
                    }
                } else {
                    return true;
                }
            } else {
                if (rule_labels.next()) |_| {
                    return false;
                } else {
                    return true;
                }
            }
        }
    }

    pub const LabelIterator = struct {
        remaining_rule: []const u8,

        pub fn next(self: *LabelIterator) ?[]const u8 {
            const last_dot_idx_opt = std.mem.lastIndexOfScalar(u8, self.remaining_rule, '.');
            if (last_dot_idx_opt) |last_dot_idx| {
                const current = self.remaining_rule[last_dot_idx + 1 ..];
                self.remaining_rule = self.remaining_rule[0..last_dot_idx];
                return current;
            } else if (self.remaining_rule.len > 0) {
                const current = self.remaining_rule;
                self.remaining_rule = "";
                return current;
            }
            return null;
        }
    };
};

pub const Division = enum { iana, private };

pub const QueryOptions = struct {
    division_filter: ?std.EnumSet(Division) = null,
};

test "rhs label iterator" {
    const rule = Rule.init("some.rule.example", null);
    var iter = rule.labelIter();

    try std.testing.expectEqualStrings("example", iter.next() orelse unreachable);
    try std.testing.expectEqualStrings("rule", iter.next() orelse unreachable);
    try std.testing.expectEqualStrings("some", iter.next() orelse unreachable);
    try std.testing.expectEqual(null, iter.next());
}

test "public suffix database tests" {
    const database_str =
        \\com
        \\*.foo.com
        \\*.jp
        \\*.hokkaido.jp
        \\*.tokyo.jp
        \\!pref.hokkaido.jp
        \\!metro.tokyo.jp
    ;
    var stream = std.io.fixedBufferStream(database_str);
    var database = try PublicSuffixDatabase.parse(std.testing.allocator, stream.reader());
    defer database.deinit(std.testing.allocator);

    try std.testing.expectEqual(null, database.evaluate("jp", .{}));
    try std.testing.expectEqual(null, database.getPublicSuffix("jp", .{}));

    try std.testing.expectEqualStrings("com", database.evaluate("com", .{}).?.raw_rule_text);
    try std.testing.expectEqualStrings("com", database.getPublicSuffix("com", .{}).?);
    try std.testing.expectEqual(null, database.getPublicSuffixPlusOne("com", .{}));

    try std.testing.expectEqualStrings("*.jp", database.evaluate("example.lol.jp", .{}).?.raw_rule_text);
    try std.testing.expectEqualStrings("*.jp", database.evaluate("example.lol.jp", .{}).?.rule_text);
    try std.testing.expectEqualStrings("lol.jp", database.getPublicSuffix("example.lol.jp", .{}).?);
    try std.testing.expectEqualStrings("example.lol.jp", database.getPublicSuffixPlusOne("example.lol.jp", .{}).?);
    try std.testing.expectEqualStrings("!metro.tokyo.jp", database.evaluate("wowie.metro.tokyo.jp", .{}).?.raw_rule_text);
    try std.testing.expectEqualStrings("metro.tokyo.jp", database.evaluate("wowie.metro.tokyo.jp", .{}).?.rule_text);
    try std.testing.expectEqualStrings("tokyo.jp", database.getPublicSuffix("wowie.metro.tokyo.jp", .{}).?);
    try std.testing.expectEqualStrings("metro.tokyo.jp", database.getPublicSuffixPlusOne("wowie.metro.tokyo.jp", .{}).?);
}

test "division filter" {
    const database_str =
        \\// ===BEGIN ICANN DOMAINS===
        \\icann
        \\// ===END ICANN DOMAINS===
        \\// ===BEGIN PRIVATE DOMAINS===
        \\lol.private
        \\// ===END PRIVATE DOMAINS===
    ;
    var stream = std.io.fixedBufferStream(database_str);

    var suffix_db = try PublicSuffixDatabase.parse(std.testing.allocator, stream.reader());
    defer suffix_db.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("icann", suffix_db.getPublicSuffix("grr.icann", .{ .division_filter = std.EnumSet(Division).initOne(.iana) }).?);
    try std.testing.expectEqual(null, suffix_db.getPublicSuffix("grr.private", .{ .division_filter = std.EnumSet(Division).initOne(.iana) }));

    try std.testing.expectEqual(null, suffix_db.getPublicSuffix("grr.icann", .{ .division_filter = std.EnumSet(Division).initOne(.private) }));
    try std.testing.expectEqualStrings("lol.private", suffix_db.getPublicSuffix("grr.lol.private", .{ .division_filter = std.EnumSet(Division).initOne(.private) }).?);
}

test {
    // explicitly test punycode since it is private
    _ = punycode;
}
