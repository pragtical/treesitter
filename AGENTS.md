# AGENTS.md

## Project Overview

This repository contains a Pragtical plugin that provides Tree-sitter based
syntax highlighting through a direct LuaJIT FFI wrapper around the Tree-sitter
C runtime.

The Pragtical plugin lives in `plugins/treesitter/`. The native Tree-sitter
runtime is built with Meson and installed into the same plugin directory so the
plugin manager can download the required runtime asset for the user's platform.

## Runtime Loading

The Lua FFI wrapper is implemented in `plugins/treesitter/tree_sitter.lua`.

Runtime lookup order is:

1. Bundled/downloaded runtime in the plugin directory, such as `tree-sitter.x86_64-linux.so`.
2. Explicit configured runtime path from `config.plugins.treesitter.treeSitterRuntimePath` or `TREESITTER_RUNTIME`.
3. System Tree-sitter libraries available through the platform dynamic loader.

The runtime should export `ts_parser_set_timeout_micros` so parsing can be
time-limited and deferred instead of blocking the editor.

## Lua Plugin Structure

- `plugins/treesitter/init.lua` patches Pragtical document/highlighter behavior and schedules parsing work.
- `plugins/treesitter/highlights.lua` initializes per-document parser, query, and capture runner state.
- `plugins/treesitter/languages.lua` stores language definitions, loads parser shared libraries, and resolves highlight query files.
- `plugins/treesitter/tree_sitter.lua` wraps the Tree-sitter runtime with LuaJIT FFI.
- `plugins/treesitter/style.lua` installs fallback syntax colors for Tree-sitter capture names.
- `plugins/treesitter/config.lua` defines plugin settings and the settings UI spec.
- `plugins/treesitter/util.lua` contains small path helpers.

Language support is registered by calling `plugins.treesitter.languages.addDef`.

## Build And Packaging

The root `meson.build` builds the bundled Tree-sitter runtime from the
`tree-sitter` subproject and installs both the runtime and Lua plugin files to:

```
<data_dir>/plugins/treesitter
```

The Tree-sitter subproject package files live under:

```
subprojects/packagefiles/tree-sitter/
```

Generated build directories and runtime binaries are ignored by `.gitignore`.

The plugin manifest is `manifest.json`. It declares plugin id `treesitter`,
path `plugins/treesitter`, and platform-specific runtime files hosted from the
GitHub release repo.

## Tests

Tests live in `tests/` and are intended to be run by Pragtical:

```sh
SDL_VIDEO_DRIVER=dummy pragtical test tests
```

The tests adjust `package.path` so they can require the local plugin modules
directly from this repository.

Some tests are skipped when optional external language parser libraries are
not installed locally.

## Live Testing

For live testing with the globally installed Pragtical, symlink the plugin
directory into the user plugin directory:

```sh
ln -sfn ./plugins/treesitter /home/jgm/.config/pragtical/plugins/treesitter
```

Then run Pragtical normally or with a smoke script:

```sh
SDL_VIDEO_DRIVER=dummy pragtical run -n /tmp/check_treesitter.lua
```

## Related Repository

`../treesitter-languages/` is a companion language package repository. It
generates per-language plugins from Tree-sitter grammars and Neovim highlight
queries, then publishes platform-specific zip packages.
