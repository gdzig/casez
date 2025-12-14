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
            .splits = StaticStringMap([]const []const u8).initComptime(&.{
                .{ "vector2d", &.{ "vector", "2d" } },
            }),
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
            .acronyms = StaticStringMap(void).initComptime(&.{
                .{ "http", {} },
                .{ "url", {} },
            }),
        },
    };
    try testing.expectEqualStrings("HTTPRequest", comptimeConvert(config, "http_request"));
    try testing.expectEqualStrings("ParseURL", comptimeConvert(config, "parse_url"));
    try testing.expectEqualStrings("HTTPURLParser", comptimeConvert(config, "http_url_parser"));
}

test "acronym splitting" {
    const config: Config = .{
        .first = .title,
        .rest = .title,
        .acronym = .title,
        .delimiter = "",
        .dictionary = .{
            .acronyms = StaticStringMap(void).initComptime(&.{
                .{ "xr", {} },
                .{ "vrs", {} },
            }),
        },
    };
    try testing.expectEqualStrings("XrVrs", comptimeConvert(config, "XRVRS"));
    try testing.expectEqualStrings("XrVrsHelper", comptimeConvert(config, "XRVRSHelper"));
}

test "splits dictionary" {
    // For truly ambiguous cases that can't be inferred from acronyms
    const config: Config = .{
        .first = .lower,
        .rest = .lower,
        .acronym = .lower,
        .delimiter = "_",
        .dictionary = .{
            .splits = StaticStringMap([]const []const u8).initComptime(&.{
                .{ "vector2d", &.{ "vector", "2d" } },
            }),
        },
    };
    try testing.expectEqualStrings("vector_2d", comptimeConvert(config, "Vector2D"));
}

test "prefix and suffix" {
    const prefixed: Config = comptime .withPrefix(.snake, "_");
    try testing.expectEqualStrings("_hello_world", comptimeConvert(prefixed, "helloWorld"));
    try testing.expectEqualStrings("_hello", comptimeConvert(prefixed, "hello"));

    const suffixed: Config = comptime .withSuffix(.snake, "_");
    try testing.expectEqualStrings("hello_world_", comptimeConvert(suffixed, "helloWorld"));

    const both: Config = comptime .withPrefix(.withSuffix(.snake, "_"), "_");
    try testing.expectEqualStrings("_hello_world_", comptimeConvert(both, "helloWorld"));

    // Prefix with camel case (for virtual methods like _someMethod)
    const prefixed_camel: Config = comptime .withPrefix(.camel, "_");
    try testing.expectEqualStrings("_someMethod", comptimeConvert(prefixed_camel, "some_method"));
    try testing.expectEqualStrings("_enterTree", comptimeConvert(prefixed_camel, "enter_tree"));
}

test "detection" {
    try testing.expect(casez.isSnake("hello_world"));
    try testing.expect(casez.isSnake("_private"));
    try testing.expect(!casez.isSnake("helloWorld"));
    try testing.expect(!casez.isSnake("HelloWorld"));

    try testing.expect(casez.isCamel("helloWorld"));
    try testing.expect(!casez.isCamel("HelloWorld"));
    try testing.expect(!casez.isCamel("hello_world"));

    try testing.expect(casez.isPascal("HelloWorld"));
    try testing.expect(!casez.isPascal("helloWorld"));
    try testing.expect(!casez.isPascal("hello_world"));

    try testing.expect(casez.isConstant("HELLO_WORLD"));
    try testing.expect(!casez.isConstant("hello_world"));

    try testing.expect(casez.isKebab("hello-world"));
    try testing.expect(!casez.isKebab("hello_world"));
}

test "bufConvert" {
    var buf: [64]u8 = undefined;

    try testing.expectEqualStrings("hello_world", bufConvert(.snake, &buf, "HelloWorld").?);
    try testing.expectEqualStrings("helloWorld", bufConvert(.camel, &buf, "hello_world").?);
    try testing.expectEqualStrings("HelloWorld", bufConvert(.pascal, &buf, "hello_world").?);
    try testing.expectEqualStrings("HELLO_WORLD", bufConvert(.constant, &buf, "helloWorld").?);
    try testing.expectEqualStrings("hello-world", bufConvert(.kebab, &buf, "HelloWorld").?);
}

test "allocConvert" {
    const allocator = testing.allocator;

    const snake = try allocConvert(.snake, allocator, "HelloWorld");
    defer allocator.free(snake);
    try testing.expectEqualStrings("hello_world", snake);

    const camel = try allocConvert(.camel, allocator, "hello_world");
    defer allocator.free(camel);
    try testing.expectEqualStrings("helloWorld", camel);

    const pascal = try allocConvert(.pascal, allocator, "hello_world");
    defer allocator.free(pascal);
    try testing.expectEqualStrings("HelloWorld", pascal);
}

const std = @import("std");
const testing = std.testing;
const casez = @import("casez.zig");
const allocConvert = casez.allocConvert;
const bufConvert = casez.bufConvert;
const comptimeConvert = casez.comptimeConvert;
const Config = casez.Config;
const StaticStringMap = std.StaticStringMap;
