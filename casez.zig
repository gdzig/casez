/// Comptime case conversion, returns a comptime string slice.
pub fn comptimeConvert(comptime config: Config, comptime input: []const u8) []const u8 {
    const words = comptime expandWords(config, parseWords(input));

    comptime var buf: [outputLen(config, words)]u8 = undefined;
    comptime var pos: usize = 0;

    inline for (config.prefix, 0..) |p, j| buf[pos + j] = p;
    pos += config.prefix.len;

    inline for (words, 0..) |word, i| {
        if (comptime i > 0) {
            inline for (config.delimiter, 0..) |d, j| buf[pos + j] = d;
            pos += config.delimiter.len;
        }

        const policy = comptime wordPolicy(config, word, i);
        inline for (word, 0..) |c, j| {
            buf[pos + j] = comptime applyCase(policy, c, j);
        }
        pos += word.len;
    }

    inline for (config.suffix, 0..) |s, j| buf[pos + j] = s;
    pos += config.suffix.len;

    const out = buf;
    return &out;
}

/// Runtime case conversion into a provided buffer.
pub fn bufConvert(comptime config: Config, buf: []u8, input: []const u8) ?[]u8 {
    var words: [256][]const u8 = undefined;
    var word_count: usize = 0;

    // Parse words
    var start: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];

        if (!ascii.isAlphanumeric(c)) {
            if (i > start) {
                if (word_count >= words.len) return null;
                words[word_count] = input[start..i];
                word_count += 1;
            }
            start = i + 1;
            continue;
        }

        if (i > start and isWordBoundaryRuntime(input, i)) {
            if (word_count >= words.len) return null;
            words[word_count] = input[start..i];
            word_count += 1;
            start = i;
        }
    }

    if (input.len > start) {
        if (word_count >= words.len) return null;
        words[word_count] = input[start..];
        word_count += 1;
    }

    // Write output
    var pos: usize = 0;

    if (pos + config.prefix.len > buf.len) return null;
    @memcpy(buf[pos..][0..config.prefix.len], config.prefix);
    pos += config.prefix.len;

    for (words[0..word_count], 0..) |word, word_idx| {
        if (word_idx > 0) {
            if (pos + config.delimiter.len > buf.len) return null;
            @memcpy(buf[pos..][0..config.delimiter.len], config.delimiter);
            pos += config.delimiter.len;
        }

        const policy = wordPolicyRuntime(config, word, word_idx);
        for (word, 0..) |c, char_idx| {
            if (pos >= buf.len) return null;
            buf[pos] = applyCaseRuntime(policy, c, char_idx);
            pos += 1;
        }
    }

    if (pos + config.suffix.len > buf.len) return null;
    @memcpy(buf[pos..][0..config.suffix.len], config.suffix);
    pos += config.suffix.len;

    return buf[0..pos];
}

/// Runtime case conversion with allocation.
pub fn allocConvert(comptime config: Config, allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Worst case: every char becomes a word with delimiter, plus prefix and suffix
    const max_len = config.prefix.len + input.len + input.len * config.delimiter.len + config.suffix.len;
    const buf = try allocator.alloc(u8, max_len);

    if (bufConvert(config, buf, input)) |result| {
        if (result.len < buf.len) {
            return allocator.realloc(buf, result.len) catch result;
        }
        return result;
    } else {
        allocator.free(buf);
        return error.ConversionFailed;
    }
}

/// Length of the final converted string.
fn outputLen(comptime config: Config, comptime words: []const []const u8) usize {
    comptime var len: usize = config.prefix.len;
    for (words, 0..) |word, i| {
        if (i > 0) len += config.delimiter.len;
        len += word.len;
    }
    len += config.suffix.len;
    return len;
}

/// Case policy for a word based on position and acronym status.
fn wordPolicy(comptime config: Config, comptime word: []const u8, comptime index: usize) Config.Case {
    if (config.dictionary.acronyms.get(word) != null) return config.acronym;
    if (index == 0) return config.first;
    return config.rest;
}

/// Transformed character with case applied.
fn applyCase(comptime policy: Config.Case, comptime c: u8, comptime index: usize) u8 {
    return switch (policy) {
        .upper => ascii.toUpper(c),
        .lower => ascii.toLower(c),
        .title => if (index == 0) ascii.toUpper(c) else ascii.toLower(c),
    };
}

/// Runtime version of applyCase.
fn applyCaseRuntime(policy: Config.Case, c: u8, index: usize) u8 {
    return switch (policy) {
        .upper => ascii.toUpper(c),
        .lower => ascii.toLower(c),
        .title => if (index == 0) ascii.toUpper(c) else ascii.toLower(c),
    };
}

/// Runtime version of wordPolicy (without dictionary support).
fn wordPolicyRuntime(config: Config, word: []const u8, index: usize) Config.Case {
    if (config.dictionary.acronyms.get(word) != null) return config.acronym;
    if (index == 0) return config.first;
    return config.rest;
}

/// Runtime version of isWordBoundary.
fn isWordBoundaryRuntime(input: []const u8, i: usize) bool {
    const prev = input[i - 1];
    const curr = input[i];
    const next: ?u8 = if (i + 1 < input.len) input[i + 1] else null;

    if (ascii.isLower(prev) and ascii.isUpper(curr)) return true;

    if (ascii.isUpper(prev) and ascii.isUpper(curr)) {
        if (next) |n| if (ascii.isLower(n)) return true;
    }

    if (ascii.isDigit(prev) and ascii.isUpper(curr)) {
        if (next) |n| if (ascii.isLower(n)) return true;
    }

    return false;
}

/// Words after applying splits dictionary and acronym-based splitting.
fn expandWords(comptime config: Config, comptime words: []const []const u8) []const []const u8 {
    comptime var total: usize = 0;
    for (words) |word| {
        total += if (config.dictionary.splits.get(word)) |s| s.len else splitByAcronyms(config, word).len;
    }

    comptime var result: [total][]const u8 = undefined;
    comptime var i: usize = 0;
    for (words) |word| {
        const expanded = config.dictionary.splits.get(word) orelse splitByAcronyms(config, word);
        for (expanded) |w| {
            result[i] = w;
            i += 1;
        }
    }

    const out = result;
    return &out;
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
    for (config.dictionary.acronyms.keys()) |acronym| {
        if (pos + acronym.len <= word.len and std.mem.eql(u8, word[pos..][0..acronym.len], acronym)) {
            return acronym;
        }
    }
    return null;
}

/// Input split into lowercase words by delimiters and case boundaries.
fn parseWords(comptime input: []const u8) []const []const u8 {
    comptime var words: [input.len][]const u8 = undefined;
    comptime var count: usize = 0;
    comptime var start: usize = 0;
    comptime var i: usize = 0;

    while (i < input.len) : (i += 1) {
        const c = input[i];

        if (isDelimiter(c)) {
            if (i > start) {
                words[count] = lowercase(input[start..i]);
                count += 1;
            }
            start = i + 1;
            continue;
        }

        if (i > start and isWordBoundary(input, i)) {
            words[count] = lowercase(input[start..i]);
            count += 1;
            start = i;
        }
    }

    if (input.len > start) {
        words[count] = lowercase(input[start..]);
        count += 1;
    }

    const out = words;
    return out[0..count];
}

/// Any non-alphanumeric character is a delimiter.
fn isDelimiter(c: u8) bool {
    return !ascii.isAlphanumeric(c);
}

/// True if a new word starts at this position.
fn isWordBoundary(comptime input: []const u8, comptime i: usize) bool {
    const prev = input[i - 1];
    const curr = input[i];
    const next: ?u8 = if (i + 1 < input.len) input[i + 1] else null;

    // "helloWorld" -> "hello", "World"
    if (ascii.isLower(prev) and ascii.isUpper(curr)) return true;

    // "HTTPRequest" -> "HTTP", "Request"
    if (ascii.isUpper(prev) and ascii.isUpper(curr)) {
        if (next) |n| if (ascii.isLower(n)) return true;
    }

    // "Base64Encoder" -> "Base64", "Encoder"
    if (ascii.isDigit(prev) and ascii.isUpper(curr)) {
        if (next) |n| if (ascii.isLower(n)) return true;
    }

    return false;
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
    dictionary: Dictionary = .empty,

    pub const Case = enum { upper, title, lower };

    pub const Dictionary = struct {
        acronyms: StaticStringMap(void) = .initComptime(&.{}),
        splits: StaticStringMap([]const []const u8) = .initComptime(&.{}),

        pub const empty: Dictionary = .{};
    };

    pub const snake: Config = .{ .first = .lower, .rest = .lower, .acronym = .lower, .delimiter = "_" };
    pub const camel: Config = .{ .first = .lower, .rest = .title, .acronym = .lower, .delimiter = "" };
    pub const pascal: Config = .{ .first = .title, .rest = .title, .acronym = .title, .delimiter = "" };
    pub const constant: Config = .{ .first = .upper, .rest = .upper, .acronym = .upper, .delimiter = "_" };
    pub const kebab: Config = .{ .first = .lower, .rest = .lower, .acronym = .lower, .delimiter = "-" };
    pub const title: Config = .{ .first = .title, .rest = .title, .acronym = .title, .delimiter = " " };

    pub fn withDictionary(base: Config, dictionary: Dictionary) Config {
        return .{
            .first = base.first,
            .rest = base.rest,
            .acronym = base.acronym,
            .delimiter = base.delimiter,
            .prefix = base.prefix,
            .suffix = base.suffix,
            .dictionary = dictionary,
        };
    }

    pub fn withPrefix(base: Config, prefix: []const u8) Config {
        return .{
            .first = base.first,
            .rest = base.rest,
            .acronym = base.acronym,
            .delimiter = base.delimiter,
            .prefix = prefix,
            .suffix = base.suffix,
            .dictionary = base.dictionary,
        };
    }

    pub fn withSuffix(base: Config, suffix: []const u8) Config {
        return .{
            .first = base.first,
            .rest = base.rest,
            .acronym = base.acronym,
            .delimiter = base.delimiter,
            .prefix = base.prefix,
            .suffix = suffix,
            .dictionary = base.dictionary,
        };
    }
};

// Detection

pub fn isSnake(input: []const u8) bool {
    for (input) |c| {
        if (ascii.isUpper(c)) return false;
        if (c != '_' and !ascii.isAlphanumeric(c)) return false;
    }
    return true;
}

pub fn isCamel(input: []const u8) bool {
    if (input.len == 0) return false;
    if (ascii.isUpper(input[0])) return false;
    for (input) |c| if (!ascii.isAlphanumeric(c)) return false;
    return true;
}

pub fn isPascal(input: []const u8) bool {
    if (input.len == 0) return false;
    if (!ascii.isUpper(input[0])) return false;
    for (input) |c| if (!ascii.isAlphanumeric(c)) return false;
    return true;
}

pub fn isConstant(input: []const u8) bool {
    for (input) |c| {
        if (ascii.isLower(c)) return false;
        if (c != '_' and !ascii.isAlphanumeric(c)) return false;
    }
    return true;
}

pub fn isKebab(input: []const u8) bool {
    for (input) |c| {
        if (ascii.isUpper(c)) return false;
        if (c != '-' and !ascii.isAlphanumeric(c)) return false;
    }
    return true;
}

test {
    _ = @import("tests.zig");
}

const std = @import("std");
const ascii = std.ascii;
const StaticStringMap = std.StaticStringMap;
