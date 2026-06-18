# Treesitter

Tree-sitter syntax highlighting for [Pragtical](https://pragtical.dev), using a
direct LuaJIT FFI binding to the Tree-sitter C runtime.

## Requirements

- Pragtical built with LuaJIT.
- A Tree-sitter runtime library. Plugin-manager installs use the bundled
  runtime asset for the current platform.
- Language parser plugins, such as `treesitter_lua` or `treesitter_c`.

## Install

With Pragtical's plugin manager:

```sh
pragtical pm install treesitter
```

For local development, symlink the plugin directory:

```sh
ln -sfn /path/to/treesitter/plugins/treesitter ~/.config/pragtical/plugins/treesitter
```

## Runtime Loading

Treesitter loads the Tree-sitter runtime in this order:

1. A bundled/downloaded runtime in the plugin directory, for example
   `tree-sitter.x86_64-linux.so`.
2. `config.plugins.treesitter.treeSitterRuntimePath`, or `TREESITTER_RUNTIME`.
3. A system Tree-sitter library available to the platform loader.

The runtime should export `ts_parser_set_timeout_micros`. If it does not, the
plugin disables Tree-sitter highlighting for the document instead of allowing a
parse to block the editor.

## Language Support

Install language packages from
[pragtical/treesitter-languages](https://github.com/pragtical/treesitter-languages):

```sh
pragtical pm repo add https://github.com/pragtical/treesitter-languages.git:master
pragtical pm install treesitter_lua
pragtical pm install treesitter_c
```

Language packages register parser libraries and highlight queries with:

```lua
require "plugins.treesitter.languages"
```

## Manual Language Definition

You can register a parser and query manually from your user module:

```lua
local languages = require "plugins.treesitter.languages"

languages.addDef {
  name = "foo",
  files = { "%.foo$", "%.bar$" },
  path = "~/tree-sitter-foo",
  soFile = "parser{SOEXT}",
  queryFiles = {
    highlights = "queries/highlights.scm",
  },
}
```

Fields:

| Option | Description |
| --- | --- |
| `name` | Tree-sitter language name. Must be unique. |
| `files` | Lua patterns used to match document filenames. |
| `path` | Base directory for the parser and query files. |
| `soFile` | Parser library path relative to `path`. `{SOEXT}` expands to `.so` or `.dll`. |
| `queryFiles.highlights` | Highlight query path relative to `path`. |

Definitions without `files` can still provide inherited query text for other
languages.

## Highlight Queries

The plugin is designed around Neovim-style Tree-sitter highlight queries. It
supports common highlight predicates such as `#eq?`, `#any-eq?`, `#match?`,
`#any-match?`, `#contains?`, `#any-of?`, `#has-parent?`, and
`#has-ancestor?`. Query inheritance comments such as `; inherits: c` are also
handled.

Capture names map directly to Pragtical syntax names. `style.lua` installs
fallback colors for many common Tree-sitter capture groups.

## Configuration

Options are available under `Plugins > Treesitter` in Pragtical settings, or
through `core.config`:

```lua
local config = require "core.config"

config.plugins.treesitter.maxParseTime = 2000
config.plugins.treesitter.treeSitterRuntimePath = "/path/to/libtree-sitter.so"
config.plugins.treesitter.useFallbackColors = true
config.plugins.treesitter.warnFallbackColors = true
```

| Option | Default | Description |
| --- | --- | --- |
| `maxParseTime` | `2000` | Maximum parse time in microseconds before parsing is deferred. Use `0` to disable deferring. |
| `treeSitterRuntimePath` | `nil` | Optional explicit Tree-sitter runtime path. |
| `useFallbackColors` | `true` | Fill missing Tree-sitter capture colors from existing syntax colors. |
| `warnFallbackColors` | `true` | Warn when fallback colors are installed. |

## Development

Build the bundled runtime with Meson:

```sh
meson setup build -Darch_tuple=x86_64-linux -Ddata_dir=/
meson compile -C build
```

Run tests inside Pragtical:

```sh
SDL_VIDEO_DRIVER=dummy pragtical test tests
```

## License

MIT
