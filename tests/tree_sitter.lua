local test = require "core.test"

local function dirname(path)
  return path:match("^(.*)[/\\][^/\\]+$") or "."
end

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function repo_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return dirname(dirname(source))
end

package.path = join_path(repo_root(), "?.lua") .. ";" ..
  join_path(repo_root(), "?", "init.lua") .. ";" ..
  package.path

local ts = require "plugins.treesitter.tree_sitter"

local function parser_path()
  return join_path(
    repo_root(),
    "..",
    "tree-sitter",
    "install",
    "libraries",
    "tree-sitter-lua",
    "libtree-sitter-lua." .. ARCH .. (PLATFORM == "Windows" and ".dll" or ".so")
  )
end

local function node_text(lines, node)
  local start_pt = node:start_point()
  local end_pt = node:end_point()
  local start_row, start_col = start_pt:row() + 1, start_pt:column() + 1
  local end_row, end_col = end_pt:row() + 1, end_pt:column() + 1

  if start_row == end_row then
    return lines[start_row]:sub(start_col, end_col - 1)
  end

  local parts = { lines[start_row]:sub(start_col) }
  for row = start_row + 1, end_row - 1 do
    parts[#parts + 1] = lines[row]
  end
  parts[#parts + 1] = lines[end_row]:sub(1, end_col - 1)
  return table.concat(parts)
end

local function parse_lines(parser, old_tree, lines)
  return parser:parse(old_tree, function(_, point)
    return lines[point:row() + 1]
  end)
end

test.describe("treesitter ffi", function()
  test.it("loads a runtime and creates parsers", function()
    test.type(ts.runtime, "string")
    test.not_equal(ts.runtime, "")
    local parser = test.not_nil(ts.Parser.new())
    test.equal(parser:has_timeout(), ts.has_timeout)
  end)

  test.it("loads a language, parses, edits, queries and filters predicates", function()
    test.skip_if(not ts.has_timeout, "runtime does not support parse timeouts: " .. ts.runtime)

    local path = parser_path()
    test.skip_if(not system.get_file_info(path), "tree-sitter-lua parser is not installed at " .. path)

    local lang = ts.Language.load(path, "lua")
    local parser = ts.Parser.new()
    test.ok(parser:set_language(lang))
    parser:set_timeout_micros(0)

    local lines = {
      "local x = 1\n",
      "local y = 2\n",
    }
    local tree = test.not_nil(parse_lines(parser, nil, lines))

    lines[2] = "local z = 2\n"
    tree:edit(
      #lines[1] + #"local ",
      #lines[1] + #"local y",
      #lines[1] + #"local z",
      ts.Point.new(1, #"local "),
      ts.Point.new(1, #"local y"),
      ts.Point.new(1, #"local z")
    )
    tree = test.not_nil(parse_lines(parser, tree, lines))

    local query = ts.Query.new(lang, '((identifier) @variable (#eq? @variable "z"))')
    local cursor = ts.Query.Cursor.new(query, tree:root_node())
    local runner = ts.Query.Runner.new({
      ["eq?"] = function(nodes, expected)
        for _, node in ipairs(nodes:nodes()) do
          if node_text(lines, node) ~= expected then return false end
        end
        return true
      end,
    })

    local captures = {}
    for capture in runner:iter_captures(cursor) do
      captures[#captures + 1] = {
        name = capture:name(),
        text = node_text(lines, capture:node()),
      }
    end

    test.same(captures, {
      { name = "variable", text = "z" },
    })
  end)

  test.it("preserves absolute language and query paths", function()
    local languages = require "plugins.treesitter.languages"
    local path = parser_path()
    local query_path = join_path(
      repo_root(),
      "..",
      "tree-sitter",
      "subprojects",
      "tree-sitter-lua",
      "queries",
      "highlights.scm"
    )

    languages.addDef {
      name = "treesitter_test_lua_paths",
      files = { "%.treesitter-test-lua$" },
      path = "/usr/lib",
      soFile = path,
      queryFiles = {
        highlights = query_path,
      },
    }

    local def = languages.defs.treesitter_test_lua_paths
    test.equal(def.soFile, path)
    test.equal(def.queryFiles.highlights, query_path)
  end)
end)
