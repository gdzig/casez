pub const BufConvertError = error{NoSpaceLeft};

/// Comptime case conversion, returns a pointer to a null-terminated comptime array.
pub fn comptimeConvert(comptime config: Config, comptime input: []const u8) *const [comptimeOutputLen(config, input):0]u8 {
    const words = comptime expandWords(config, parseWords(config, input));
    const len = comptime outputLen(config, words);

    comptime var buf: [len:0]u8 = undefined;
    comptime var pos: usize = 0;

    inline for (config.prefix, 0..) |p, j| buf[pos + j] = p;
    pos += config.prefix.len;

    inline for (words, 0..) |word, i| {
        if (comptime i > 0) {
            const prev_word = words[i - 1];
            if (comptime !shouldJoin(config, prev_word, word)) {
                inline for (config.delimiter, 0..) |d, j| buf[pos + j] = d;
                pos += config.delimiter.len;
            }
        }

        const policy = comptime wordPolicy(config, word, i);
        inline for (word, 0..) |c, j| {
            buf[pos + j] = comptime applyCase(policy, c, j);
        }
        pos += word.len;
    }

    inline for (config.suffix, 0..) |s, j| buf[pos + j] = s;
    pos += config.suffix.len;

    buf[len] = 0;

    const out = buf;
    return &out;
}

/// Runtime case conversion into a provided buffer.
pub fn bufConvert(buf: []u8, comptime config: Config, input: []const u8) BufConvertError![]u8 {
    var w = Writer.fixed(buf);
    writeConvert(&w, config, input) catch return error.NoSpaceLeft;
    return w.buffered();
}

/// Runtime case conversion into a provided buffer, with sentinel.
pub fn bufConvertSentinel(buf: []u8, comptime config: Config, input: []const u8, comptime sentinel: u8) BufConvertError![:sentinel]u8 {
    if (buf.len == 0) return error.NoSpaceLeft;
    const result = try bufConvert(buf[0 .. buf.len - 1], config, input);
    buf[result.len] = sentinel;
    return buf[0..result.len :sentinel];
}

/// Runtime case conversion with allocation.
pub fn allocConvert(allocator: Allocator, comptime config: Config, input: []const u8) Allocator.Error![]u8 {
    var aw = Allocating.init(allocator);
    errdefer aw.deinit();
    writeConvert(&aw.writer, config, input) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
    return aw.toOwnedSlice();
}

/// Runtime case conversion with allocation, with sentinel.
pub fn allocConvertSentinel(allocator: Allocator, comptime config: Config, input: []const u8, comptime sentinel: u8) Allocator.Error![:sentinel]u8 {
    var aw = Allocating.init(allocator);
    errdefer aw.deinit();
    writeConvert(&aw.writer, config, input) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
    return aw.toOwnedSliceSentinel(sentinel);
}

/// Runtime case conversion that writes directly to a writer.
pub fn writeConvert(writer: *Writer, comptime config: Config, input: []const u8) anyerror!void {
    var segments: [256][]const u8 = undefined;
    var segment_count: usize = 0;

    // Parse segments (will be split further if all-uppercase)
    var start: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];

        if (!ascii.isAlphanumeric(c)) {
            if (i > start) {
                if (segment_count >= segments.len) return error.TooManySegments;
                segments[segment_count] = input[start..i];
                segment_count += 1;
            }
            start = i + 1;
            continue;
        }

        if (i > start and isWordBoundary(config, input, i)) {
            if (segment_count >= segments.len) return error.TooManySegments;
            segments[segment_count] = input[start..i];
            segment_count += 1;
            start = i;
        }
    }

    if (input.len > start) {
        if (segment_count >= segments.len) return error.TooManySegments;
        segments[segment_count] = input[start..];
        segment_count += 1;
    }

    // Write output
    try writer.writeAll(config.prefix);

    var global_word_idx: usize = 0;
    var prev_word_buf: [64]u8 = undefined;
    var prev_word_len: usize = 0;

    for (segments[0..segment_count]) |segment| {
        // Check if segment is all-uppercase
        var all_upper = true;
        for (segment) |c| {
            if (ascii.isAlphabetic(c) and ascii.isLower(c)) {
                all_upper = false;
                break;
            }
        }

        if (all_upper) {
            // Split by acronyms
            var seg_pos: usize = 0;
            while (seg_pos < segment.len) {
                const acronym = findAcronymAtInput(config, segment, seg_pos);
                const word_len = if (acronym) |a| a.len else segment.len - seg_pos;
                const word = segment[seg_pos..][0..word_len];

                // Lowercase the word for join checking
                var lower_word_buf: [64]u8 = undefined;
                for (word, 0..) |wc, wi| lower_word_buf[wi] = ascii.toLower(wc);
                const lower_word = lower_word_buf[0..word_len];

                if (global_word_idx > 0) {
                    const prev_word = prev_word_buf[0..prev_word_len];
                    if (!shouldJoinRuntime(config, prev_word, lower_word)) {
                        try writer.writeAll(config.delimiter);
                    }
                }

                const policy = wordPolicy(config, lower_word, global_word_idx);
                for (word, 0..) |c, char_idx| {
                    try writer.writeByte(applyCase(policy, c, char_idx));
                }

                // Save this word as prev for next iteration
                @memcpy(prev_word_buf[0..word_len], lower_word);
                prev_word_len = word_len;

                global_word_idx += 1;
                seg_pos += word_len;
            }
        } else {
            // Lowercase the segment for join checking and policy
            var lower_seg_buf: [64]u8 = undefined;
            for (segment, 0..) |sc, si| lower_seg_buf[si] = ascii.toLower(sc);
            const lower_seg = lower_seg_buf[0..segment.len];

            if (global_word_idx > 0) {
                const prev_word = prev_word_buf[0..prev_word_len];
                if (!shouldJoinRuntime(config, prev_word, lower_seg)) {
                    try writer.writeAll(config.delimiter);
                }
            }

            const policy = wordPolicy(config, lower_seg, global_word_idx);
            for (segment, 0..) |c, char_idx| {
                try writer.writeByte(applyCase(policy, c, char_idx));
            }

            // Save this word as prev for next iteration
            @memcpy(prev_word_buf[0..segment.len], lower_seg);
            prev_word_len = segment.len;

            global_word_idx += 1;
        }
    }

    try writer.writeAll(config.suffix);
}

/// Length of the final converted string from raw input.
fn comptimeOutputLen(comptime config: Config, comptime input: []const u8) usize {
    @setEvalBranchQuota(10_000);
    return outputLen(config, expandWords(config, parseWords(config, input)));
}

/// Length of the final converted string.
fn outputLen(comptime config: Config, comptime words: []const []const u8) usize {
    comptime var len: usize = config.prefix.len;
    for (words, 0..) |word, i| {
        if (i > 0 and !shouldJoin(config, words[i - 1], word)) {
            len += config.delimiter.len;
        }
        len += word.len;
    }
    len += config.suffix.len;
    return len;
}

/// Case policy for a word based on position and acronym status.
fn wordPolicy(comptime config: Config, word: []const u8, index: usize) Config.Case {
    if (isAcronym(config, word)) return config.acronym;
    if (index == 0) return config.first;
    return config.rest;
}

/// Check if a word is in the acronyms list.
fn isAcronym(comptime config: Config, word: []const u8) bool {
    inline for (config.dictionary.acronyms) |acronym| {
        if (std.mem.eql(u8, word, acronym)) return true;
    }
    return false;
}

/// Transformed character with case applied.
fn applyCase(policy: Config.Case, c: u8, index: usize) u8 {
    return switch (policy) {
        .upper => ascii.toUpper(c),
        .lower => ascii.toLower(c),
        .title => if (index == 0) ascii.toUpper(c) else ascii.toLower(c),
    };
}

/// Words after applying splits dictionary.
fn expandWords(comptime config: Config, comptime words: []const []const u8) []const []const u8 {
    comptime var total: usize = 0;
    for (words) |word| {
        total += if (findSplit(config, word)) |_| 2 else 1;
    }

    comptime var result: [total][]const u8 = undefined;
    comptime var i: usize = 0;
    for (words) |word| {
        if (findSplit(config, word)) |split| {
            result[i] = split[0];
            i += 1;
            result[i] = split[1];
            i += 1;
        } else {
            result[i] = word;
            i += 1;
        }
    }

    const out = result;
    return &out;
}

/// Find a split for a word by concatenating split parts and comparing.
fn findSplit(comptime config: Config, word: []const u8) ?[2][]const u8 {
    for (config.dictionary.splits) |split| {
        const joined = split[0] ++ split[1];
        if (std.mem.eql(u8, word, joined)) return split;
    }
    return null;
}

/// Check if two adjacent words should be joined (no delimiter between them).
fn shouldJoin(comptime config: Config, comptime prev_word: []const u8, comptime next_word: []const u8) bool {
    const joined = prev_word ++ next_word;
    for (config.dictionary.joins) |join| {
        if (std.mem.eql(u8, joined, join)) return true;
    }
    return false;
}

/// Runtime check if two adjacent words should be joined.
fn shouldJoinRuntime(comptime config: Config, prev_word: []const u8, next_word: []const u8) bool {
    if (config.dictionary.joins.len == 0) return false;
    const total_len = prev_word.len + next_word.len;
    for (config.dictionary.joins) |join| {
        if (join.len == total_len and
            std.mem.eql(u8, join[0..prev_word.len], prev_word) and
            std.mem.eql(u8, join[prev_word.len..], next_word))
        {
            return true;
        }
    }
    return false;
}

/// Word split by matching known acronyms from the start.
fn splitByAcronyms(comptime config: Config, comptime word: []const u8) []const []const u8 {
    comptime var count: usize = 0;
    comptime var pos: usize = 0;

    while (pos < word.len) {
        const acronym = findAcronymAt(config, word, pos);
        count += 1;
        pos += if (acronym) |a| a.len else word.len - pos;
    }

    comptime var result: [count][]const u8 = undefined;
    comptime var i: usize = 0;
    pos = 0;

    while (pos < word.len) {
        if (findAcronymAt(config, word, pos)) |acronym| {
            result[i] = acronym;
            pos += acronym.len;
        } else {
            result[i] = word[pos..];
            pos = word.len;
        }
        i += 1;
    }

    const out = result;
    return &out;
}

/// Acronym matching at position, or null.
fn findAcronymAt(comptime config: Config, comptime word: []const u8, comptime pos: usize) ?[]const u8 {
    for (config.dictionary.acronyms) |acronym| {
        if (pos + acronym.len <= word.len and std.mem.eql(u8, word[pos..][0..acronym.len], acronym)) {
            return acronym;
        }
    }
    return null;
}

/// Input split into lowercase words by delimiters and case boundaries.
/// Detects acronyms from the dictionary and keeps them as single words.
fn parseWords(comptime config: Config, comptime input: []const u8) []const []const u8 {
    comptime var words: [input.len][]const u8 = undefined;
    comptime var count: usize = 0;
    comptime var start: usize = 0;
    comptime var i: usize = 0;

    while (i < input.len) : (i += 1) {
        const c = input[i];

        if (isDelimiter(c)) {
            if (i > start) {
                const segment = input[start..i];
                const split = splitUppercaseSegment(config, segment);
                for (split) |w| {
                    words[count] = w;
                    count += 1;
                }
            }
            start = i + 1;
            continue;
        }

        if (i > start and isWordBoundary(config, input, i)) {
            const segment = input[start..i];
            const split = splitUppercaseSegment(config, segment);
            for (split) |w| {
                words[count] = w;
                count += 1;
            }
            start = i;
        }
    }

    if (input.len > start) {
        const segment = input[start..];
        const split = splitUppercaseSegment(config, segment);
        for (split) |w| {
            words[count] = w;
            count += 1;
        }
    }

    const out = words;
    return out[0..count];
}

/// Split an all-uppercase segment by acronyms, or return as single lowercase word.
fn splitUppercaseSegment(comptime config: Config, comptime segment: []const u8) []const []const u8 {
    // Only split if the entire segment is uppercase (like "XRVRS" or "HTTP")
    comptime var all_upper = true;
    for (segment) |c| {
        if (ascii.isAlphabetic(c) and ascii.isLower(c)) {
            all_upper = false;
            break;
        }
    }

    if (all_upper) {
        // Use acronym splitting for all-uppercase segments
        return splitByAcronyms(config, lowercase(segment));
    } else {
        // Mixed case - just lowercase the whole thing
        const result: [1][]const u8 = .{lowercase(segment)};
        const out = result;
        return &out;
    }
}

/// Any non-alphanumeric character is a delimiter.
fn isDelimiter(c: u8) bool {
    return !ascii.isAlphanumeric(c);
}

/// True if a new word starts at this position.
fn isWordBoundary(comptime config: Config, input: []const u8, i: usize) bool {
    const prev = input[i - 1];
    const curr = input[i];
    const next: ?u8 = if (i + 1 < input.len) input[i + 1] else null;

    // Check if we're inside a known acronym - if so, never split
    if (isInsideAcronym(config, input, i)) return false;

    // "helloWorld" -> "hello", "World"
    if (ascii.isLower(prev) and ascii.isUpper(curr)) return true;

    // "HTTPRequest" -> "HTTP", "Request"
    if (ascii.isUpper(prev) and ascii.isUpper(curr)) {
        // Check if current position starts a known acronym
        if (findAcronymAtInput(config, input, i)) |_| return true;
        // Standard boundary: uppercase followed by lowercase (end of acronym run)
        if (next) |n| if (ascii.isLower(n)) return true;
    }

    // "Base64Encoder" -> "Base64", "Encoder"
    if (ascii.isDigit(prev) and ascii.isUpper(curr)) {
        if (next) |n| if (ascii.isLower(n)) return true;
    }

    // "Node2d" -> "Node", "2d" (letter followed by digit starts new word)
    if (config.digit_boundary and ascii.isAlphabetic(prev) and ascii.isDigit(curr)) return true;

    return false;
}

/// Check if position i is inside (but not at the start of) a known acronym.
fn isInsideAcronym(comptime config: Config, input: []const u8, i: usize) bool {
    // Look backwards to find if an acronym started before position i and extends past it
    for (config.dictionary.acronyms) |acronym| {
        // Check all possible start positions that would include position i
        const start_min: usize = if (i >= acronym.len) i - acronym.len + 1 else 0;
        var start: usize = start_min;
        while (start < i) : (start += 1) {
            // Only consider acronyms that start at valid word boundaries
            if (!isValidAcronymStart(input, start)) continue;

            if (start + acronym.len <= input.len) {
                var matches = true;
                for (acronym, 0..) |ac, j| {
                    if (ascii.toLower(input[start + j]) != ascii.toLower(ac)) {
                        matches = false;
                        break;
                    }
                }
                if (matches) {
                    // Acronym starts at `start` and covers position i
                    return true;
                }
            }
        }
    }
    return false;
}

/// Check if a position is a valid place for an acronym to start.
/// Acronyms can only be detected at: start of input, after delimiter, or at uppercase letter.
fn isValidAcronymStart(input: []const u8, pos: usize) bool {
    // Start of input is always valid
    if (pos == 0) return true;

    const prev = input[pos - 1];
    const curr = input[pos];

    // After a delimiter is valid
    if (!ascii.isAlphanumeric(prev)) return true;

    // Uppercase letter after lowercase is valid (normal word boundary)
    if (ascii.isLower(prev) and ascii.isUpper(curr)) return true;

    // Within an all-uppercase run is valid (consecutive uppercase letters)
    if (ascii.isUpper(prev) and ascii.isUpper(curr)) return true;

    // Otherwise not valid (e.g., lowercase in the middle of a word like "Xrvrs")
    return false;
}

/// Find acronym at position in original (non-lowercased) input.
fn findAcronymAtInput(comptime config: Config, input: []const u8, pos: usize) ?[]const u8 {
    // Only detect acronyms at valid word boundaries
    if (!isValidAcronymStart(input, pos)) return null;

    for (config.dictionary.acronyms) |acronym| {
        if (pos + acronym.len <= input.len) {
            // Compare case-insensitively
            var matches = true;
            for (acronym, 0..) |ac, j| {
                if (ascii.toLower(input[pos + j]) != ascii.toLower(ac)) {
                    matches = false;
                    break;
                }
            }
            if (matches) return acronym;
        }
    }
    return null;
}

/// Input with all characters lowercased.
fn lowercase(comptime input: []const u8) []const u8 {
    comptime var result: [input.len]u8 = undefined;
    for (input, 0..) |c, i| result[i] = ascii.toLower(c);
    const out = result;
    return &out;
}

// Config

pub const Config = struct {
    first: Case,
    rest: Case,
    acronym: Case,
    delimiter: []const u8,
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    digit_boundary: bool = false,
    dictionary: Dictionary = .empty,

    pub const Case = enum { upper, title, lower };

    pub const Dictionary = struct {
        acronyms: []const []const u8 = &.{},
        splits: []const [2][]const u8 = &.{},
        joins: []const []const u8 = &.{},

        pub const empty: Dictionary = .{};
    };

    pub const snake: Config = .{ .first = .lower, .rest = .lower, .acronym = .lower, .delimiter = "_" };
    pub const camel: Config = .{ .first = .lower, .rest = .title, .acronym = .title, .delimiter = "" };
    pub const pascal: Config = .{ .first = .title, .rest = .title, .acronym = .title, .delimiter = "" };
    pub const constant: Config = .{ .first = .upper, .rest = .upper, .acronym = .upper, .delimiter = "_" };
    pub const kebab: Config = .{ .first = .lower, .rest = .lower, .acronym = .lower, .delimiter = "-" };
    pub const title: Config = .{ .first = .title, .rest = .title, .acronym = .title, .delimiter = " " };

    pub fn with(base: Config, overrides: anytype) Config {
        var new = base;
        inline for (std.meta.fields(@TypeOf(overrides))) |field| {
            @field(new, field.name) = @field(overrides, field.name);
        }
        return new;
    }
};

// Detection

pub fn is(comptime config: Config, input: []const u8) bool {
    if (input.len == 0) return false;

    // Check prefix
    if (config.prefix.len > 0) {
        if (input.len < config.prefix.len) return false;
        if (!std.mem.eql(u8, input[0..config.prefix.len], config.prefix)) return false;
    }

    // Check suffix
    if (config.suffix.len > 0) {
        if (input.len < config.suffix.len) return false;
        if (!std.mem.eql(u8, input[input.len - config.suffix.len ..], config.suffix)) return false;
    }

    // Get the content between prefix and suffix
    const content = input[config.prefix.len .. input.len - config.suffix.len];
    if (content.len == 0) return config.prefix.len > 0 or config.suffix.len > 0;

    // For configs with no delimiter (camel, pascal), check first char and ensure no non-alphanumeric
    if (config.delimiter.len == 0) {
        // Check first character matches expected case
        const first = content[0];
        if (!ascii.isAlphabetic(first)) return false;
        switch (config.first) {
            .lower => if (ascii.isUpper(first)) return false,
            .upper => if (ascii.isLower(first)) return false,
            .title => if (ascii.isLower(first)) return false,
        }
        // Rest must be alphanumeric only
        for (content[1..]) |c| {
            if (!ascii.isAlphanumeric(c)) return false;
        }
        return true;
    }

    // For configs with delimiter, parse words
    var word_idx: usize = 0;
    var char_idx: usize = 0;
    var i: usize = 0;

    while (i < content.len) {
        const c = content[i];

        // Check for delimiter
        if (i + config.delimiter.len <= content.len) {
            if (std.mem.eql(u8, content[i..][0..config.delimiter.len], config.delimiter)) {
                if (char_idx == 0) return false; // Empty word or leading delimiter
                word_idx += 1;
                char_idx = 0;
                i += config.delimiter.len;
                continue;
            }
        }

        // Determine expected case for this character
        const expected_case = if (word_idx == 0) config.first else config.rest;
        const is_first_char = char_idx == 0;

        if (!ascii.isAlphanumeric(c)) return false;

        switch (expected_case) {
            .lower => if (ascii.isUpper(c)) return false,
            .upper => if (ascii.isLower(c)) return false,
            .title => {
                if (is_first_char) {
                    if (ascii.isLower(c)) return false;
                } else {
                    if (ascii.isUpper(c)) return false;
                }
            },
        }

        char_idx += 1;
        i += 1;
    }

    return true;
}

test {
    _ = @import("tests.zig");
}

const std = @import("std");
const ascii = std.ascii;
const Allocator = std.mem.Allocator;
const Allocating = std.Io.Writer.Allocating;
const StaticStringMap = std.StaticStringMap;
const Writer = std.Io.Writer;
