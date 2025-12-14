# casez

Flexible case conversion library for Zig with comptime and runtime support. 

This library was created to address the more esoteric case conversion needs of [gdzig](https://github.com/gdzig/gdzig).

## Usage

```zig
const casez = @import("casez");

// Comptime conversion
const snake = casez.comptimeConvert(.snake, "helloWorld"); // "hello_world"
const pascal = casez.comptimeConvert(.pascal, "hello_world"); // "HelloWorld"

// Runtime conversion (buffer-based)
var buf: [64]u8 = undefined;
const result = casez.bufConvert(.camel, &buf, input);

// Runtime conversion (allocating)
const allocated = try casez.allocConvert(.kebab, allocator, input);
defer allocator.free(allocated);
```

## Configs

- `.snake` - `hello_world`
- `.camel` - `helloWorld`
- `.pascal` - `HelloWorld`
- `.constant` - `HELLO_WORLD`
- `.kebab` - `hello-world`
- `.title` - `Hello World`

## Custom Configs

For advanced use cases, you can create custom configs to control acronym casing and handle ambiguous word boundaries.

### Acronym Dictionary

Preserve acronym casing in output:

```zig
const config: casez.Config = .{
    .first = .title,
    .rest = .title,
    .acronym = .upper,  // acronyms get uppercased
    .delimiter = "",
    .dictionary = .{
        .acronyms = .initComptime(&.{
            .{ "http", {} },
            .{ "url", {} },
        }),
    },
};

comptimeConvert(config, "http_request");    // "HTTPRequest"
comptimeConvert(config, "parse_url");       // "ParseURL"
comptimeConvert(config, "http_url_parser"); // "HTTPURLParser"
```

Acronyms are also used to split ambiguous input like `"XRVRS"` into separate words when both `"xr"` and `"vrs"` are defined.

### Splits Dictionary

Explicitly define how ambiguous words should be split:

```zig
const config: casez.Config = .{
    .first = .lower,
    .rest = .lower,
    .acronym = .lower,
    .delimiter = "_",
    .dictionary = .{
        .splits = .initComptime(&.{
            .{ "vector2d", &.{ "vector", "2d" } },
        }),
    },
};

comptimeConvert(config, "Vector2D"); // "vector_2d"
```

### Prefix and Suffix

Add a custom prefix or suffix string:

```zig
const prefixed: casez.Config = comptime .withPrefix(.snake, "_");
comptimeConvert(prefixed, "helloWorld"); // "_hello_world"

const suffixed: casez.Config = comptime .withSuffix(.snake, "_");
comptimeConvert(suffixed, "helloWorld"); // "hello_world_"

// Useful for virtual methods: _someMethod from some_method
const prefixed_camel: casez.Config = comptime .withPrefix(.camel, "_");
comptimeConvert(prefixed_camel, "some_method"); // "_someMethod"
```

### Helpers

Use helper methods to extend built-in configs:

```zig
const custom: casez.Config = comptime .withDictionary(.pascal, .{
    .acronyms = .initComptime(&.{
        .{ "http", {} },
    }),
});

const prefixed = custom.withPrefix("_");
const suffixed = custom.withSuffix("_");
```

## License

MIT
