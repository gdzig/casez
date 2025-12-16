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

    buf[len] = 0;

    const out = buf;
    return &out;
}

/// Runtime case conversion into a provided buffer.
pub fn bufConvert(comptime config: Config, buf: []u8, input: []const u8) BufConvertError![]u8 {
    var segments: [256][]const u8 = undefined;
    var segment_count: usize = 0;

    // Parse segments (will be split further if all-uppercase)
    var start: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];

        if (!ascii.isAlphanumeric(c)) {
            if (i > start) {
                if (segment_count >= segments.len) return error.NoSpaceLeft;
                segments[segment_count] = input[start..i];
                segment_count += 1;
            }
            start = i + 1;
            continue;
        }

        if (i > start and isWordBoundaryRuntime(config, input, i)) {
            if (segment_count >= segments.len) return error.NoSpaceLeft;
            segments[segment_count] = input[start..i];
            segment_count += 1;
            start = i;
        }
    }

    if (input.len > start) {
        if (segment_count >= segments.len) return error.NoSpaceLeft;
        segments[segment_count] = input[start..];
        segment_count += 1;
    }

    // Write output
    var pos: usize = 0;

    if (pos + config.prefix.len > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[pos..][0..config.prefix.len], config.prefix);
    pos += config.prefix.len;

    var global_word_idx: usize = 0;
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
                const acronym = findAcronymAtInputRuntime(config, segment, seg_pos);
                const word_len = if (acronym) |a| a.len else segment.len - seg_pos;
                const word = segment[seg_pos..][0..word_len];

                if (global_word_idx > 0) {
                    if (pos + config.delimiter.len > buf.len) return error.NoSpaceLeft;
                    @memcpy(buf[pos..][0..config.delimiter.len], config.delimiter);
                    pos += config.delimiter.len;
                }

                const policy = wordPolicyRuntime(config, word, global_word_idx);
                for (word, 0..) |c, char_idx| {
                    if (pos >= buf.len) return error.NoSpaceLeft;
                    buf[pos] = applyCaseRuntime(policy, c, char_idx);
                    pos += 1;
                }

                global_word_idx += 1;
                seg_pos += word_len;
            }
        } else {
            // Single word
            if (global_word_idx > 0) {
                if (pos + config.delimiter.len > buf.len) return error.NoSpaceLeft;
                @memcpy(buf[pos..][0..config.delimiter.len], config.delimiter);
                pos += config.delimiter.len;
            }

            const policy = wordPolicyRuntime(config, segment, global_word_idx);
            for (segment, 0..) |c, char_idx| {
                if (pos >= buf.len) return error.NoSpaceLeft;
                buf[pos] = applyCaseRuntime(policy, c, char_idx);
                pos += 1;
            }

            global_word_idx += 1;
        }
    }

    if (pos + config.suffix.len > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[pos..][0..config.suffix.len], config.suffix);
    pos += config.suffix.len;

    return buf[0..pos];
}

/// Runtime case conversion into a provided buffer, with sentinel.
pub fn bufConvertSentinel(comptime config: Config, buf: []u8, input: []const u8, comptime sentinel: u8) BufConvertError![:sentinel]u8 {
    if (buf.len == 0) return error.NoSpaceLeft;
    const result = try bufConvert(config, buf[0 .. buf.len - 1], input);
    buf[result.len] = sentinel;
    return buf[0..result.len :sentinel];
}

/// Runtime case conversion with allocation.
pub fn allocConvert(comptime config: Config, allocator: Allocator, input: []const u8) Allocator.Error![]u8 {
    // Worst case: every char becomes a word with delimiter, plus prefix and suffix
    const max_len = config.prefix.len + input.len + input.len * config.delimiter.len + config.suffix.len;
    const buf = try allocator.alloc(u8, max_len);

    const result = bufConvert(config, buf, input) catch unreachable;
    if (result.len < buf.len) {
        return allocator.realloc(buf, result.len) catch result;
    }
    return result;
}

/// Runtime case conversion with allocation, with sentinel.
pub fn allocConvertSentinel(comptime config: Config, allocator: Allocator, input: []const u8, comptime sentinel: u8) Allocator.Error![:sentinel]u8 {
    // Worst case: every char becomes a word with delimiter, plus prefix and suffix, plus sentinel
    const max_len = config.prefix.len + input.len + input.len * config.delimiter.len + config.suffix.len + 1;
    const buf = try allocator.alloc(u8, max_len);

    const result = bufConvertSentinel(config, buf, input, sentinel) catch unreachable;
    if (result.len + 1 < buf.len) {
        const new_buf = allocator.realloc(buf, result.len + 1) catch buf;
        return new_buf[0..result.len :sentinel];
    }
    return result;
}

/// Runtime case conversion that writes directly to a writer.
pub fn writeConvert(writer: *std.Io.Writer, comptime config: Config, input: []const u8) anyerror!void {
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

        if (i > start and isWordBoundaryRuntime(config, input, i)) {
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
                const acronym = findAcronymAtInputRuntime(config, segment, seg_pos);
                const word_len = if (acronym) |a| a.len else segment.len - seg_pos;
                const word = segment[seg_pos..][0..word_len];

                if (global_word_idx > 0) {
                    try writer.writeAll(config.delimiter);
                }

                const policy = wordPolicyRuntime(config, word, global_word_idx);
                for (word, 0..) |c, char_idx| {
                    try writer.writeByte(applyCaseRuntime(policy, c, char_idx));
                }

                global_word_idx += 1;
                seg_pos += word_len;
            }
        } else {
            // Single word
            if (global_word_idx > 0) {
                try writer.writeAll(config.delimiter);
            }

            const policy = wordPolicyRuntime(config, segment, global_word_idx);
            for (segment, 0..) |c, char_idx| {
                try writer.writeByte(applyCaseRuntime(policy, c, char_idx));
            }

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
fn isWordBoundaryRuntime(comptime config: Config, input: []const u8, i: usize) bool {
    const prev = input[i - 1];
    const curr = input[i];
    const next: ?u8 = if (i + 1 < input.len) input[i + 1] else null;

    // Check if we're inside a known acronym - if so, never split
    if (isInsideAcronymRuntime(config, input, i)) return false;

    if (ascii.isLower(prev) and ascii.isUpper(curr)) return true;

    if (ascii.isUpper(prev) and ascii.isUpper(curr)) {
        // Check if current position starts a known acronym
        if (findAcronymAtInputRuntime(config, input, i)) |_| return true;
        if (next) |n| if (ascii.isLower(n)) return true;
    }

    if (ascii.isDigit(prev) and ascii.isUpper(curr)) {
        if (next) |n| if (ascii.isLower(n)) return true;
    }

    return false;
}

/// Runtime version of isInsideAcronym.
fn isInsideAcronymRuntime(comptime config: Config, input: []const u8, i: usize) bool {
    for (config.dictionary.acronyms.keys()) |acronym| {
        const start_min: usize = if (i >= acronym.len) i - acronym.len + 1 else 0;
        var start: usize = start_min;
        while (start < i) : (start += 1) {
            // Only consider acronyms that start at valid word boundaries
            if (!isValidAcronymStartRuntime(input, start)) continue;

            if (start + acronym.len <= input.len) {
                var matches = true;
                for (acronym, 0..) |ac, j| {
                    if (ascii.toLower(input[start + j]) != ascii.toLower(ac)) {
                        matches = false;
                        break;
                    }
                }
                if (matches) return true;
            }
        }
    }
    return false;
}

/// Runtime version of isValidAcronymStart.
fn isValidAcronymStartRuntime(input: []const u8, pos: usize) bool {
    if (pos == 0) return true;

    const prev = input[pos - 1];
    const curr = input[pos];

    if (!ascii.isAlphanumeric(prev)) return true;
    if (ascii.isLower(prev) and ascii.isUpper(curr)) return true;
    if (ascii.isUpper(prev) and ascii.isUpper(curr)) return true;

    return false;
}

/// Runtime version of findAcronymAtInput.
fn findAcronymAtInputRuntime(comptime config: Config, input: []const u8, pos: usize) ?[]const u8 {
    // Only detect acronyms at valid word boundaries
    if (!isValidAcronymStartRuntime(input, pos)) return null;

    for (config.dictionary.acronyms.keys()) |acronym| {
        if (pos + acronym.len <= input.len) {
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

/// Words after applying splits dictionary.
fn expandWords(comptime config: Config, comptime words: []const []const u8) []const []const u8 {
    comptime var total: usize = 0;
    for (words) |word| {
        total += if (config.dictionary.splits.get(word)) |s| s.len else 1;
    }

    comptime var result: [total][]const u8 = undefined;
    comptime var i: usize = 0;
    for (words) |word| {
        if (config.dictionary.splits.get(word)) |split_words| {
            for (split_words) |w| {
                result[i] = w;
                i += 1;
            }
        } else {
            result[i] = word;
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
fn isWordBoundary(comptime config: Config, comptime input: []const u8, comptime i: usize) bool {
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

    return false;
}

/// Check if position i is inside (but not at the start of) a known acronym.
fn isInsideAcronym(comptime config: Config, comptime input: []const u8, comptime i: usize) bool {
    // Look backwards to find if an acronym started before position i and extends past it
    for (config.dictionary.acronyms.keys()) |acronym| {
        // Check all possible start positions that would include position i
        comptime var start: usize = if (i >= acronym.len) i - acronym.len + 1 else 0;
        while (start < i) : (start += 1) {
            // Only consider acronyms that start at valid word boundaries
            if (!isValidAcronymStart(input, start)) continue;

            if (start + acronym.len <= input.len) {
                comptime var matches = true;
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
fn isValidAcronymStart(comptime input: []const u8, comptime pos: usize) bool {
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
fn findAcronymAtInput(comptime config: Config, comptime input: []const u8, comptime pos: usize) ?[]const u8 {
    // Only detect acronyms at valid word boundaries
    if (!isValidAcronymStart(input, pos)) return null;

    for (config.dictionary.acronyms.keys()) |acronym| {
        if (pos + acronym.len <= input.len) {
            // Compare case-insensitively
            comptime var matches = true;
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
    dictionary: Dictionary = .empty,

    pub const Case = enum { upper, title, lower };

    pub const Dictionary = struct {
        acronyms: StaticStringMap(void) = .initComptime(&.{}),
        splits: StaticStringMap([]const []const u8) = .initComptime(&.{}),

        pub const empty: Dictionary = .{};
    };

    pub const snake: Config = .{ .first = .lower, .rest = .lower, .acronym = .lower, .delimiter = "_" };
    pub const camel: Config = .{ .first = .lower, .rest = .title, .acronym = .title, .delimiter = "" };
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

    pub fn withAcronym(base: Config, acronym: Case) Config {
        return .{
            .first = base.first,
            .rest = base.rest,
            .acronym = acronym,
            .delimiter = base.delimiter,
            .prefix = base.prefix,
            .suffix = base.suffix,
            .dictionary = base.dictionary,
        };
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
const StaticStringMap = std.StaticStringMap;
