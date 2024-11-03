const std = @import("std");

// based on https://github.com/mathiasbynens/punycode.js/blob/main/punycode.js#L290 (MIT Licensed by Mathias Bynens)

const base = 36;
const t_min = 1;
const t_max = 26;
const skew = 38;
const damp = 700;
const initial_bias = 72;
const initial_n = 0x80;
const delimiter = '-'; // '\x2D'
const max_int: u32 = std.math.maxInt(i32);

pub fn encode(input: []const u8, writer: anytype) !void {
    const utf8view = try std.unicode.Utf8View.init(input);

    var basic_length: usize = 0;
    var ascii_iter = utf8view.iterator();
    while (ascii_iter.nextCodepoint()) |codepoint| {
        if (codepoint < 128) {
            try writer.writeByte(@intCast(codepoint));
            basic_length += 1;
        }
    }

    var handled_codepoint_count: u32 = std.math.cast(u32, basic_length) orelse return error.Overflow;

    if (basic_length > 0) {
        try writer.writeByte(delimiter);
    }

    var n: u32 = initial_n;
    var delta: u32 = 0;
    var bias: u8 = initial_bias;

    // main encoding loop
    const input_len = try std.unicode.utf8CountCodepoints(input);
    while (handled_codepoint_count < input_len) {
        // the smallest codepoint that is >= min_codepoint
        var m: u32 = max_int;
        var iterator = utf8view.iterator();

        while (iterator.nextCodepoint()) |current_value| {
            if (current_value >= n and current_value < m) {
                m = current_value;
            }
        }

        // Increase `delta` enough to advance the decoder's <n,i> state to <m,0>,
        // but guard against overflow.
        if (m - n > @divFloor(max_int - delta, handled_codepoint_count + 1)) {
            return error.Overflow;
        }

        delta += (m - n) * (handled_codepoint_count + 1);
        n = m;

        iterator = utf8view.iterator();
        while (iterator.nextCodepoint()) |current_value| {
            if (current_value < n) {
                delta += 1;
                if (delta > max_int) {
                    return error.Overflow;
                }
            }

            if (current_value == n) {
                // Represent delta as a generalized variable-length integer.
                var q: u32 = delta;
                var k: u32 = base;
                while (true) : (k += base) {
                    const t: u32 = if (k <= bias) t_min else if (k >= bias + t_max) t_max else k - bias;
                    if (q < t) {
                        break;
                    }

                    const digit = std.math.cast(u8, t + (q - t) % (base - t)) orelse return error.Overflow;
                    try writer.writeByte(try digitToBasic(digit, false));
                    q = @divFloor(q - t, base - t);
                }

                try writer.writeByte(try digitToBasic(std.math.cast(u8, q) orelse return error.Overflow, false));
                bias = try adapt(delta, handled_codepoint_count + 1, handled_codepoint_count == basic_length);
                delta = 0;
                handled_codepoint_count += 1;
            }
        }

        delta += 1;
        n += 1;
    }
}

fn digitToBasic(digit: u8, flag: bool) !u8 {
    //  0..25 map to ASCII a..z or A..Z
    // 26..35 map to ASCII 0..9
    var result = digit + 22;
    if (digit < 26) {
        result += 75;
    }
    if (flag) {
        result -= (1 << 5);
    }
    return result;
}

fn adapt(delta_param: u32, num_points: usize, first_time: bool) !u8 {
    var k: u8 = 0;
    var delta = if (first_time) @divFloor(delta_param, damp) else delta_param >> 1;
    delta += @divFloor(delta, std.math.cast(u32, num_points) orelse return error.Overflow);

    while (delta > (base - t_min) * t_max >> 1) : (k += base) {
        delta = @divFloor(delta, base - t_min);
    }
    // old: (k + (base - t_min + 1) * delta) / (delta + skew)
    // new: k + ((base - t_min + 1) * delta) / (delta + skew)
    return k + (std.math.cast(u8, @divFloor((base - t_min + 1) * delta, delta + skew)) orelse return error.Overflow);
}

test "punycode encode - wikipedia examples" {
    try expectEncode("", "");
    try expectEncode("a", "a-");
    try expectEncode("A", "A-");
    try expectEncode("3", "3-");
    try expectEncode("-", "--");
    try expectEncode("--", "---");
    try expectEncode("London", "London-");
    try expectEncode("Lloyd-Atkinson", "Lloyd-Atkinson-");
    try expectEncode("This has spaces", "This has spaces-");
    try expectEncode("-> $1.00 <-", "-> $1.00 <--");
    try expectEncode("Б", "d0a");
    try expectEncode("ü", "tda");
    try expectEncode("α", "mxa");
    try expectEncode("例", "fsq");
    try expectEncode("😉", "n28h");
    try expectEncode("αβγ", "mxacd");
    try expectEncode("München", "Mnchen-3ya");
    try expectEncode("Mnchen-3ya", "Mnchen-3ya-");
    try expectEncode("München-Ost", "Mnchen-Ost-9db");
    try expectEncode("Bahnhof München-Ost", "Bahnhof Mnchen-Ost-u6b");
    try expectEncode("abæcdöef", "abcdef-qua4k");
    try expectEncode("правда", "80aafi6cg");
    try expectEncode("ยจฆฟคฏข", "22cdfh1b8fsa");
    try expectEncode("도메인", "hq1bm8jm9l");
    try expectEncode("ドメイン名例", "eckwd4c7cu47r2wf");
    try expectEncode("MajiでKoiする5秒前", "MajiKoi5-783gue6qz075azm5e");
    try expectEncode("「bücher」", "bcher-kva8445foa");
}

fn expectEncode(input: []const u8, expected: []const u8) !void {
    var actual = std.ArrayList(u8).init(std.testing.allocator);
    defer actual.deinit();

    try encode(input, actual.writer());
    try std.testing.expectEqualStrings(expected, actual.items);
}
