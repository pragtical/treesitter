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

The bundled runtime is expected to be preferred when present. System runtime
loading is a fallback for local testing or distributions that already provide a
compatible Tree-sitter shared library.

The runtime binary names are platform-qualified:

- `tree-sitter.x86_64-linux.so`
- `tree-sitter.aarch64-linux.so`
- `tree-sitter.x86_64-darwin.so`
- `tree-sitter.aarch64-darwin.so`
- `tree-sitter.x86_64-windows.dll`

## Lua Plugin Structure

- `plugins/treesitter/init.lua` patches Pragtical document/highlighter behavior and schedules parsing work.
- `plugins/treesitter/highlights.lua` initializes per-document parser, query, and capture runner state.
- `plugins/treesitter/languages.lua` stores language definitions, loads parser shared libraries, and resolves highlight query files.
- `plugins/treesitter/tree_sitter.lua` wraps the Tree-sitter runtime with LuaJIT FFI.
- `plugins/treesitter/style.lua` installs fallback syntax colors for Tree-sitter capture names.
- `plugins/treesitter/config.lua` defines plugin settings and the settings UI spec.
- `plugins/treesitter/util.lua` contains small path helpers.

Language support is registered by calling `plugins.treesitter.languages.addDef`.

`languages.lua` accepts absolute parser and query paths. Query loading trims
leading semicolon comment/header lines before compiling the query, and must
handle EOF safely when a query file contains only those header lines.

The bundled/highlight query format is intentionally close to Neovim
Tree-sitter highlight queries. Some Neovim-specific query features or capture
conventions may need translation before they work in Pragtical.

## Language Injection

`highlights.lua` models each document as a tree of `LanguageTree` nodes (the
root language plus any injected languages), closely following Neovim's
`languagetree.lua`. A definition may declare an optional `injections` query
file via `queryFiles.injections`; the companion `treesitter-languages`
generator emits one whenever the grammar ships `injections.scm`. Injected
languages resolve by name through `languages.resolveLang`, so the corresponding
language plugin must be installed for the injection to highlight.

Key behaviors to preserve when changing this code:

- A `LanguageTree` holds one Tree-sitter tree per injected region (`trees[i]` is
  parallel to `regions[i]`). Each non-combined injection match becomes its own
  region/tree; `injection.combined` merges a pattern's matches into a single
  region. This keeps separate code blocks from sharing parser state.
- The standard injection metadata is supported: `injection.language`,
  `injection.self`, `injection.parent`, `injection.filename`,
  `injection.content`, `injection.combined`, and `injection.include-children`,
  plus the `set!`, `offset!`, `gsub!`, and `trim!` directives.
- All parsing (root and injected) runs in the backgrounded reparse thread in
  `init.lua` and is time-sliced, so it must stay coroutine-driven and abortable
  when an edit arrives mid-parse. Injection parsing must not happen in the
  render/`tokenize_line` path.
- `tokenize_line` only queries trees whose region intersects the row, merges
  captures from every covering tree, and applies deeper (injected) captures last
  so they win over the parent. Capture nodes from `iter_captures`/`iter_matches`
  alias the cursor's transient buffer: read their data immediately, never store
  the wrapped node to inspect after the iterator advances.

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

Use plain Meson commands for local and CI builds. Do not add a wrapper build
entrypoint just for CI.

Example local build:

```sh
meson setup build --buildtype=release -Darch_tuple=x86_64-linux -Ddata_dir=/
meson compile -C build
meson install -C build --destdir "$PWD/package"
```

## Release Workflow

The release repository is `pragtical/treesitter`.

`.github/workflows/build.yml` builds runtime binaries for Linux, macOS, and
Windows. It publishes every build to the `continuous` prerelease. When the
commit is associated with a `v*` tag, it also publishes assets to the versioned
release, updates the `latest` release, and force-updates the `latest` branch/tag
and `continuous` tag.

The workflow has a manual `workflow_dispatch` input named `release_tag`. Use it
to republish a version from the fixed workflow without moving an existing tag.

For a normal patch release:

```sh
git status
git pull --ff-only origin master
# edit and commit the fix, including manifest.json version bump
git tag vX.Y.Z
git push origin master
git push origin vX.Y.Z
```

Push the commit before the tag so the release workflow builds from a published
commit. If a versioned release misses assets, run the workflow manually from
`master` with `release_tag` set to the existing tag, for example `v0.5.1`.

The shared Pragtical plugin index lives in `../plugins/manifest.json`. After a
release, update its `treesitter` entry to the new version and commit hash. The
legacy addon entry and the old `tree_sitter` library entry should not be
restored.

Use `pragtical pm` in documentation and examples.

## Tests

Tests live in `tests/` and are intended to be run by Pragtical:

```sh
SDL_VIDEO_DRIVER=dummy pragtical test tests
```

The tests adjust `package.path` so they can require the local plugin modules
directly from this repository.

Some tests are skipped when optional external language parser libraries are
not installed locally.

Run tests with the globally installed Pragtical, not from `../pragtical/`:

```sh
SDL_VIDEO_DRIVER=dummy pragtical test tests
```

The Pragtical test helper library is available at
`../pragtical/data/core/test.lua`, and example upstream tests live in
`../pragtical/scripts/lua/tests/`.

Optional language parser tests may look for parser libraries under sibling
Tree-sitter install paths. A skip for a missing optional parser is acceptable
when the runtime and path tests pass.

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

The user plugin directory already exists on this machine. The live symlink
target is expected to be:

```sh
/home/jgm/.config/pragtical/plugins/treesitter -> /home/jgm/Development/GitHub/pragtical/treesitter/plugins/treesitter
```

To test with a system Tree-sitter runtime, make sure no bundled runtime shadows
it, or set `config.plugins.treesitter.treeSitterRuntimePath` /
`TREESITTER_RUNTIME` explicitly.

## Related Repository

`../treesitter-languages/` is a companion language package repository. It
generates per-language plugins from Tree-sitter grammars and Neovim highlight
queries, then publishes platform-specific zip packages.

Language package docs and examples should reference the `master` branch. Use
`pragtical pm repo add https://github.com/pragtical/treesitter-languages.git:master`
when documenting installation from that repository.

Keep this repository focused on the core runtime wrapper and highlighting
engine. Language grammars, parser builds, generated language plugins, and
per-language package release automation belong in `../treesitter-languages/`.
