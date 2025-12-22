test "snake_case" {
    try testing.expectEqualStrings("hello", comptimeConvert(.snake, "hello"));
    try testing.expectEqualStrings("hello_world", comptimeConvert(.snake, "HelloWorld"));
    try testing.expectEqualStrings("hello_world", comptimeConvert(.snake, "helloWorld"));
    try testing.expectEqualStrings("hello_world", comptimeConvert(.snake, "hello_world"));
    try testing.expectEqualStrings("hello_world", comptimeConvert(.snake, "hello-world"));
    try testing.expectEqualStrings("hello_world", comptimeConvert(.snake, "HELLO_WORLD"));
    try testing.expectEqualStrings("http_request", comptimeConvert(.snake, "HTTPRequest"));
}

test "camelCase" {
    try testing.expectEqualStrings("helloWorld", comptimeConvert(.camel, "hello_world"));
    try testing.expectEqualStrings("helloWorld", comptimeConvert(.camel, "HelloWorld"));
    try testing.expectEqualStrings("helloWorld", comptimeConvert(.camel, "HELLO_WORLD"));
    try testing.expectEqualStrings("httpRequest", comptimeConvert(.camel, "HTTPRequest"));
    try testing.expectEqualStrings("requestHttp", comptimeConvert(.camel, "RequestHTTP"));
}

test "PascalCase" {
    try testing.expectEqualStrings("HelloWorld", comptimeConvert(.pascal, "hello_world"));
    try testing.expectEqualStrings("HelloWorld", comptimeConvert(.pascal, "helloWorld"));
    try testing.expectEqualStrings("HelloWorld", comptimeConvert(.pascal, "HELLO_WORLD"));
    try testing.expectEqualStrings("HttpRequest", comptimeConvert(.pascal, "HTTPRequest"));
}

test "CONSTANT_CASE" {
    try testing.expectEqualStrings("HELLO_WORLD", comptimeConvert(.constant, "hello_world"));
    try testing.expectEqualStrings("HELLO_WORLD", comptimeConvert(.constant, "helloWorld"));
    try testing.expectEqualStrings("HELLO_WORLD", comptimeConvert(.constant, "HelloWorld"));
}

test "kebab-case" {
    try testing.expectEqualStrings("hello-world", comptimeConvert(.kebab, "hello_world"));
    try testing.expectEqualStrings("hello-world", comptimeConvert(.kebab, "helloWorld"));
    try testing.expectEqualStrings("hello-world", comptimeConvert(.kebab, "HelloWorld"));
}

test "edge cases" {
    try testing.expectEqualStrings("", comptimeConvert(.snake, ""));
    try testing.expectEqualStrings("a", comptimeConvert(.snake, "a"));
    try testing.expectEqualStrings("A", comptimeConvert(.pascal, "a"));
    try testing.expectEqualStrings("abc", comptimeConvert(.snake, "ABC"));
}

test "numeric words" {
    // Digits stay attached to preceding letters, but new words start on uppercase
    try testing.expectEqualStrings("vector2d", comptimeConvert(.snake, "Vector2D"));
    try testing.expectEqualStrings("physics2d_server", comptimeConvert(.snake, "Physics2DServer"));
    try testing.expectEqualStrings("base64_encoder", comptimeConvert(.snake, "Base64Encoder"));
    try testing.expectEqualStrings("Vector2d", comptimeConvert(.pascal, "vector_2d"));
    try testing.expectEqualStrings("vector2d", comptimeConvert(.camel, "vector_2d"));

    // Use splits dictionary to explicitly split ambiguous words
    const with_splits: Config = .{
        .first = .lower,
        .rest = .lower,
        .acronym = .lower,
        .delimiter = "_",
        .dictionary = .{
            .splits = &.{.{ "vector", "2d" }},
        },
    };
    try testing.expectEqualStrings("vector_2d", comptimeConvert(with_splits, "Vector2D"));
}

test "acronym dictionary" {
    const config: Config = .{
        .first = .title,
        .rest = .title,
        .acronym = .upper,
        .delimiter = "",
        .dictionary = .{
            .acronyms = &.{ "http", "url" },
        },
    };
    try testing.expectEqualStrings("HTTPRequest", comptimeConvert(config, "http_request"));
    try testing.expectEqualStrings("ParseURL", comptimeConvert(config, "parse_url"));
    try testing.expectEqualStrings("HTTPURLParser", comptimeConvert(config, "http_url_parser"));
}

test "acronym with numeric suffix" {
    // Node2d/Node3d should convert to Node2D/Node3D when 2d/3d are in the acronym dictionary
    const config: Config = .{
        .first = .title,
        .rest = .title,
        .acronym = .upper,
        .delimiter = "",
        .digit_boundary = true,
        .dictionary = .{
            .acronyms = &.{ "2d", "3d" },
        },
    };
    try testing.expectEqualStrings("Node2D", comptimeConvert(config, "node_2d"));
    try testing.expectEqualStrings("Node3D", comptimeConvert(config, "node_3d"));
    try testing.expectEqualStrings("Physics2DServer", comptimeConvert(config, "physics_2d_server"));
    try testing.expectEqualStrings("Node2D", comptimeConvert(config, "Node2d"));
    try testing.expectEqualStrings("Node3D", comptimeConvert(config, "Node3d"));

    // Runtime version
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Node2D", try bufConvert(&buf, config, "node_2d"));
    try testing.expectEqualStrings("Node2D", try bufConvert(&buf, config, "Node2d"));
    try testing.expectEqualStrings("Node3D", try bufConvert(&buf, config, "Node3d"));
}

test "acronym splitting" {
    const config: Config = .{
        .first = .title,
        .rest = .title,
        .acronym = .title,
        .delimiter = "",
        .dictionary = .{
            .acronyms = &.{ "xr", "vrs" },
        },
    };
    try testing.expectEqualStrings("XrVrs", comptimeConvert(config, "XRVRS"));
    try testing.expectEqualStrings("XrVrsHelper", comptimeConvert(config, "XRVRSHelper"));
}

test "acronym detection only at word boundaries" {
    // Acronyms should only be detected at valid word boundaries, not in the middle of words
    const snake_xr: Config = .{
        .first = .lower,
        .rest = .lower,
        .acronym = .lower,
        .delimiter = "_",
        .dictionary = .{
            .acronyms = &.{ "xr", "vrs" },
        },
    };

    // XRVRS -> all uppercase, acronyms detected -> "xr_vrs"
    try testing.expectEqualStrings("xr_vrs", comptimeConvert(snake_xr, "XRVRS"));
    // XR_VRS -> delimiter separated, acronyms detected -> "xr_vrs"
    try testing.expectEqualStrings("xr_vrs", comptimeConvert(snake_xr, "XR_VRS"));
    // XrVrs -> title case boundaries, acronyms detected -> "xr_vrs"
    try testing.expectEqualStrings("xr_vrs", comptimeConvert(snake_xr, "XrVrs"));
    // Xrvrs -> lowercase after X, "rv" is not at a word boundary -> single word "xrvrs"
    try testing.expectEqualStrings("xrvrs", comptimeConvert(snake_xr, "Xrvrs"));

    // Runtime version
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("xr_vrs", try bufConvert(&buf, snake_xr, "XRVRS"));
    try testing.expectEqualStrings("xr_vrs", try bufConvert(&buf, snake_xr, "XrVrs"));
    try testing.expectEqualStrings("xrvrs", try bufConvert(&buf, snake_xr, "Xrvrs"));
}

test "acronym detection in input" {
    // Detect acronyms in input and keep them together as single words
    const http_aware: Config = .{
        .first = .lower,
        .rest = .lower,
        .acronym = .lower,
        .delimiter = "_",
        .dictionary = .{
            .acronyms = &.{ "http", "api" },
        },
    };

    // "RequestHTTPSomething" should detect HTTP as one word, not H-T-T-P
    try testing.expectEqualStrings("request_http_something", comptimeConvert(http_aware, "RequestHTTPSomething"));
    try testing.expectEqualStrings("http_request", comptimeConvert(http_aware, "HTTPRequest"));
    try testing.expectEqualStrings("my_http_api", comptimeConvert(http_aware, "MyHTTPAPI"));

    // Test runtime version too
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("request_http_something", try bufConvert(&buf, http_aware, "RequestHTTPSomething"));
    try testing.expectEqualStrings("http_request", try bufConvert(&buf, http_aware, "HTTPRequest"));

    // Roundtrip: snake -> pascal with uppercase acronyms -> snake
    const pascal_http: Config = .{
        .first = .title,
        .rest = .title,
        .acronym = .upper,
        .delimiter = "",
        .dictionary = http_aware.dictionary,
    };
    try testing.expectEqualStrings("RequestHTTPSomething", comptimeConvert(pascal_http, "request_http_something"));
    try testing.expectEqualStrings("HTTPRequest", comptimeConvert(pascal_http, "http_request"));
}

test "splits dictionary" {
    // For truly ambiguous cases that can't be inferred from acronyms
    const config: Config = .{
        .first = .lower,
        .rest = .lower,
        .acronym = .lower,
        .delimiter = "_",
        .dictionary = .{
            .splits = &.{.{ "vector", "2d" }},
        },
    };
    try testing.expectEqualStrings("vector_2d", comptimeConvert(config, "Vector2D"));
}

test "prefix and suffix" {
    const prefixed: Config = comptime .with(.snake, .{ .prefix = "_" });
    try testing.expectEqualStrings("_hello_world", comptimeConvert(prefixed, "helloWorld"));
    try testing.expectEqualStrings("_hello", comptimeConvert(prefixed, "hello"));

    const suffixed: Config = comptime .with(.snake, .{ .suffix = "_" });
    try testing.expectEqualStrings("hello_world_", comptimeConvert(suffixed, "helloWorld"));

    const both: Config = comptime .with(.snake, .{ .prefix = "_", .suffix = "_" });
    try testing.expectEqualStrings("_hello_world_", comptimeConvert(both, "helloWorld"));

    // Prefix with camel case (for virtual methods like _someMethod)
    const prefixed_camel: Config = comptime .with(.camel, .{ .prefix = "_" });
    try testing.expectEqualStrings("_someMethod", comptimeConvert(prefixed_camel, "some_method"));
    try testing.expectEqualStrings("_enterTree", comptimeConvert(prefixed_camel, "enter_tree"));
}

test "detection" {
    try testing.expect(casez.is(.snake, "hello_world"));
    try testing.expect(!casez.is(.snake, "_private")); // leading underscore requires prefix
    try testing.expect(casez.is(.with(.snake, .{ .prefix = "_" }), "_private")); // with prefix it works
    try testing.expect(!casez.is(.snake, "helloWorld"));
    try testing.expect(!casez.is(.snake, "HelloWorld"));

    try testing.expect(casez.is(.camel, "helloWorld"));
    try testing.expect(!casez.is(.camel, "HelloWorld"));
    try testing.expect(!casez.is(.camel, "hello_world"));

    try testing.expect(casez.is(.pascal, "HelloWorld"));
    try testing.expect(!casez.is(.pascal, "helloWorld"));
    try testing.expect(!casez.is(.pascal, "hello_world"));

    try testing.expect(casez.is(.constant, "HELLO_WORLD"));
    try testing.expect(!casez.is(.constant, "hello_world"));

    try testing.expect(casez.is(.kebab, "hello-world"));
    try testing.expect(!casez.is(.kebab, "hello_world"));
}

test "bufConvert" {
    var buf: [64]u8 = undefined;

    try testing.expectEqualStrings("hello_world", try bufConvert(&buf, .snake, "HelloWorld"));
    try testing.expectEqualStrings("helloWorld", try bufConvert(&buf, .camel, "hello_world"));
    try testing.expectEqualStrings("HelloWorld", try bufConvert(&buf, .pascal, "hello_world"));
    try testing.expectEqualStrings("HELLO_WORLD", try bufConvert(&buf, .constant, "helloWorld"));
    try testing.expectEqualStrings("hello-world", try bufConvert(&buf, .kebab, "HelloWorld"));
}

test "allocConvert" {
    const allocator = testing.allocator;

    const snake = try allocConvert(allocator, .snake, "HelloWorld");
    defer allocator.free(snake);
    try testing.expectEqualStrings("hello_world", snake);

    const camel = try allocConvert(allocator, .camel, "hello_world");
    defer allocator.free(camel);
    try testing.expectEqualStrings("helloWorld", camel);

    const pascal = try allocConvert(allocator, .pascal, "hello_world");
    defer allocator.free(pascal);
    try testing.expectEqualStrings("HelloWorld", pascal);
}

test "writeConvert" {
    var buf: [64]u8 = undefined;

    var w = std.Io.Writer.fixed(&buf);
    try writeConvert(&w, .snake, "HelloWorld");
    try testing.expectEqualStrings("hello_world", w.buffered());

    w = std.Io.Writer.fixed(&buf);
    try writeConvert(&w, .camel, "hello_world");
    try testing.expectEqualStrings("helloWorld", w.buffered());

    w = std.Io.Writer.fixed(&buf);
    try writeConvert(&w, .pascal, "hello_world");
    try testing.expectEqualStrings("HelloWorld", w.buffered());

    w = std.Io.Writer.fixed(&buf);
    try writeConvert(&w, .constant, "helloWorld");
    try testing.expectEqualStrings("HELLO_WORLD", w.buffered());

    w = std.Io.Writer.fixed(&buf);
    try writeConvert(&w, .kebab, "HelloWorld");
    try testing.expectEqualStrings("hello-world", w.buffered());

    // Test with prefix
    w = std.Io.Writer.fixed(&buf);
    try writeConvert(&w, .with(.snake, .{ .prefix = "_" }), "helloWorld");
    try testing.expectEqualStrings("_hello_world", w.buffered());
}

const std = @import("std");
const testing = std.testing;
const casez = @import("casez.zig");
const allocConvert = casez.allocConvert;
const bufConvert = casez.bufConvert;
const comptimeConvert = casez.comptimeConvert;
const writeConvert = casez.writeConvert;
const Config = casez.Config;
