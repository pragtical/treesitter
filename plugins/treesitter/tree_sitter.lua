local config = require 'plugins.treesitter.config'

if not LUAJIT then
	error('Treesitter FFI backend requires Pragtical built with LuaJIT')
end

local ffi = require 'ffi'
local unpack = table.unpack or unpack

ffi.cdef [[
typedef struct TSParser TSParser;
typedef struct TSTree TSTree;
typedef struct TSLanguage TSLanguage;
typedef struct TSQuery TSQuery;
typedef struct TSQueryCursor TSQueryCursor;

typedef struct {
	uint32_t row;
	uint32_t column;
} TSPoint;

typedef struct {
	TSPoint start_point;
	TSPoint end_point;
	uint32_t start_byte;
	uint32_t end_byte;
} TSRange;

typedef struct {
	uint32_t context[4];
	const void *id;
	const TSTree *tree;
} TSNode;

typedef enum {
	TSInputEncodingUTF8,
	TSInputEncodingUTF16
} TSInputEncoding;

typedef const char *(*TSInputRead)(void *payload, uint32_t byte_index, TSPoint position, uint32_t *bytes_read);

typedef struct {
	void *payload;
	TSInputRead read;
	TSInputEncoding encoding;
} TSInput;

typedef struct {
	uint32_t start_byte;
	uint32_t old_end_byte;
	uint32_t new_end_byte;
	TSPoint start_point;
	TSPoint old_end_point;
	TSPoint new_end_point;
} TSInputEdit;

typedef struct {
	TSNode node;
	uint32_t index;
} TSQueryCapture;

typedef struct {
	uint32_t id;
	uint16_t pattern_index;
	uint16_t capture_count;
	const TSQueryCapture *captures;
} TSQueryMatch;

typedef enum {
	TSQueryPredicateStepTypeDone,
	TSQueryPredicateStepTypeCapture,
	TSQueryPredicateStepTypeString
} TSQueryPredicateStepType;

typedef struct {
	TSQueryPredicateStepType type;
	uint32_t value_id;
} TSQueryPredicateStep;

typedef enum {
	TSQueryErrorNone = 0,
	TSQueryErrorSyntax,
	TSQueryErrorNodeType,
	TSQueryErrorField,
	TSQueryErrorCapture,
	TSQueryErrorStructure,
	TSQueryErrorLanguage
} TSQueryError;

typedef enum {
	TSQuantifierZero = 0,
	TSQuantifierZeroOrOne,
	TSQuantifierZeroOrMore,
	TSQuantifierOne,
	TSQuantifierOneOrMore
} TSQuantifier;

TSParser *ts_parser_new(void);
void ts_parser_delete(TSParser *self);
bool ts_parser_set_language(TSParser *self, const TSLanguage *language);
TSTree *ts_parser_parse(TSParser *self, const TSTree *old_tree, TSInput input);
TSTree *ts_parser_parse_string(TSParser *self, const TSTree *old_tree, const char *string, uint32_t length);
void ts_parser_reset(TSParser *self);
void ts_parser_set_timeout_micros(TSParser *self, uint64_t timeout_micros);
bool ts_parser_set_included_ranges(TSParser *self, const TSRange *ranges, uint32_t length);
uint32_t ts_language_version(const TSLanguage *self);
uint32_t ts_language_abi_version(const TSLanguage *self);

void ts_tree_delete(TSTree *self);
TSTree *ts_tree_copy(const TSTree *self);
TSNode ts_tree_root_node(const TSTree *self);
void ts_tree_edit(TSTree *self, const TSInputEdit *edit);
TSRange *ts_tree_included_ranges(const TSTree *self, uint32_t *length);

const char *ts_node_type(TSNode self);
TSPoint ts_node_start_point(TSNode self);
TSPoint ts_node_end_point(TSNode self);
uint32_t ts_node_start_byte(TSNode self);
uint32_t ts_node_end_byte(TSNode self);
TSNode ts_node_parent(TSNode self);
uint32_t ts_node_named_child_count(TSNode self);
TSNode ts_node_named_child(TSNode self, uint32_t child_index);
bool ts_node_is_null(TSNode self);

TSQuery *ts_query_new(const TSLanguage *language, const char *source, uint32_t source_len, uint32_t *error_offset, TSQueryError *error_type);
void ts_query_delete(TSQuery *self);
uint32_t ts_query_capture_count(const TSQuery *self);
uint32_t ts_query_string_count(const TSQuery *self);
const TSQueryPredicateStep *ts_query_predicates_for_pattern(const TSQuery *self, uint32_t pattern_index, uint32_t *step_count);
const char *ts_query_capture_name_for_id(const TSQuery *self, uint32_t index, uint32_t *length);
const char *ts_query_string_value_for_id(const TSQuery *self, uint32_t index, uint32_t *length);
TSQuantifier ts_query_capture_quantifier_for_id(const TSQuery *self, uint32_t pattern_index, uint32_t capture_index);
void ts_query_disable_capture(TSQuery *self, const char *name, uint32_t length);

TSQueryCursor *ts_query_cursor_new(void);
void ts_query_cursor_delete(TSQueryCursor *self);
void ts_query_cursor_exec(TSQueryCursor *self, const TSQuery *query, TSNode node);
bool ts_query_cursor_set_point_range(TSQueryCursor *self, TSPoint start_point, TSPoint end_point);
bool ts_query_cursor_next_match(TSQueryCursor *self, TSQueryMatch *match);
bool ts_query_cursor_next_capture(TSQueryCursor *self, TSQueryMatch *match, uint32_t *capture_index);

void free(void *ptr);
]]

local M = {}

local function localPath()
	local str = debug.getinfo(1, 'S').source:sub(2)
	return str:match '(.*[/\\])' or ''
end

local function joinPath(a, b)
	if a:match('[/\\]$') then return a .. b end
	return a .. PATHSEP .. b
end

local function fileExists(path)
	local f = io.open(path, 'rb')
	if f then
		f:close()
		return true
	end
	return false
end

local function libExt()
	if PLATFORM == 'Windows' then return '.dll' end
	if PLATFORM == 'Mac OS X' or PLATFORM == 'macOS' then return '.so' end
	return '.so'
end

local function runtimeCandidates()
	local dir = localPath()
	local ext = libExt()
	local bundled = {
		joinPath(dir, 'tree-sitter.' .. ARCH .. ext),
		joinPath(dir, 'libtree-sitter.' .. ARCH .. ext),
		joinPath(dir, 'tree-sitter' .. ext),
		joinPath(dir, 'libtree-sitter' .. ext),
	}

	if PLATFORM == 'Mac OS X' or PLATFORM == 'macOS' then
		bundled[#bundled + 1] = joinPath(dir, 'tree-sitter.so')
		bundled[#bundled + 1] = joinPath(dir, 'libtree-sitter.so')
	end

	local system = PLATFORM == 'Windows' and {
		'tree-sitter',
		'tree-sitter.dll',
		'libtree-sitter.dll',
	} or {
		'tree-sitter',
		'libtree-sitter.so',
		'libtree-sitter.dylib',
	}

	local candidates = {}
	for _, path in ipairs(bundled) do candidates[#candidates + 1] = path end
	if config.treeSitterRuntimePath then
		candidates[#candidates + 1] = config.treeSitterRuntimePath
	end
	for _, name in ipairs(system) do candidates[#candidates + 1] = name end
	return candidates
end

local function loadRuntime()
	local errors = {}
	for _, candidate in ipairs(runtimeCandidates()) do
		if candidate:find('[/\\]', 1) and not fileExists(candidate) then
			errors[#errors + 1] = candidate .. ': not found'
		else
			local ok, lib = pcall(ffi.load, candidate)
			if ok then return lib, candidate end
			errors[#errors + 1] = candidate .. ': ' .. tostring(lib)
		end
	end

	error('Could not load Tree-sitter runtime. Tried:\n\t' .. table.concat(errors, '\n\t'))
end

local C, runtimeName = loadRuntime()
M.runtime = runtimeName

local okSetTimeout, setTimeoutMicros = pcall(function()
	return C.ts_parser_set_timeout_micros
end)
M.has_timeout = okSetTimeout

local okLanguageAbiVersion, languageAbiVersion = pcall(function()
	return C.ts_language_abi_version
end)
local okLanguageVersion, languageVersion = pcall(function()
	return C.ts_language_version
end)

local Point = {}
Point.__index = Point

function Point.new(row, column)
	return setmetatable({ _point = ffi.new('TSPoint', row, column) }, Point)
end

function Point.wrap(point)
	return setmetatable({ _point = point }, Point)
end

function Point:row()
	return tonumber(self._point.row)
end

function Point:column()
	return tonumber(self._point.column)
end

function Point:cdata()
	return self._point
end

M.Point = { new = Point.new, pack = Point.new }

local function cpoint(point)
	return getmetatable(point) == Point and point:cdata() or point
end

local Range = {}
Range.__index = Range

function Range.new(startPoint, endPoint, startByte, endByte)
	local range = ffi.new('TSRange')
	range.start_point = cpoint(startPoint)
	range.end_point = cpoint(endPoint)
	range.start_byte = startByte
	range.end_byte = endByte
	return setmetatable({ _range = range }, Range)
end

function Range.wrap(range)
	local copy = ffi.new('TSRange')
	copy.start_point = range.start_point
	copy.end_point = range.end_point
	copy.start_byte = range.start_byte
	copy.end_byte = range.end_byte
	return setmetatable({ _range = copy }, Range)
end

function Range:start_point()
	return Point.wrap(self._range.start_point)
end

function Range:end_point()
	return Point.wrap(self._range.end_point)
end

function Range:start_byte()
	return tonumber(self._range.start_byte)
end

function Range:end_byte()
	return tonumber(self._range.end_byte)
end

function Range:cdata()
	return self._range
end

M.Range = { new = Range.new }

local function crange(range)
	return getmetatable(range) == Range and range:cdata() or range
end

local Node = {}
Node.__index = Node

local function wrapNode(node, tree)
	if C.ts_node_is_null(node) then return nil end
	return setmetatable({ _node = node, _tree = tree }, Node)
end

function Node:type()
	return ffi.string(C.ts_node_type(self._node))
end

function Node:start_point()
	return Point.wrap(C.ts_node_start_point(self._node))
end

function Node:end_point()
	return Point.wrap(C.ts_node_end_point(self._node))
end

function Node:start_byte()
	return tonumber(C.ts_node_start_byte(self._node))
end

function Node:end_byte()
	return tonumber(C.ts_node_end_byte(self._node))
end

function Node:range()
	return Range.new(self:start_point(), self:end_point(), self:start_byte(), self:end_byte())
end

function Node:parent()
	return wrapNode(C.ts_node_parent(self._node), self._tree)
end

function Node:named_child_count()
	return tonumber(C.ts_node_named_child_count(self._node))
end

function Node:named_child(index)
	return wrapNode(C.ts_node_named_child(self._node, index), self._tree)
end

local Tree = {}
Tree.__index = Tree

local function wrapTree(ptr)
	if ptr == nil then return nil end
	return setmetatable({ _ptr = ffi.gc(ptr, C.ts_tree_delete) }, Tree)
end

function Tree:root_node()
	return wrapNode(C.ts_tree_root_node(self._ptr), self)
end

function Tree:copy()
	return wrapTree(C.ts_tree_copy(self._ptr))
end

function Tree:edit(startByte, oldEndByte, newEndByte, startPoint, oldEndPoint, newEndPoint)
	local edit = ffi.new('TSInputEdit')
	edit.start_byte = startByte
	edit.old_end_byte = oldEndByte
	edit.new_end_byte = newEndByte
	edit.start_point = cpoint(startPoint)
	edit.old_end_point = cpoint(oldEndPoint)
	edit.new_end_point = cpoint(newEndPoint)
	C.ts_tree_edit(self._ptr, edit)
end

function Tree:included_ranges()
	local len = ffi.new('uint32_t[1]')
	local ptr = C.ts_tree_included_ranges(self._ptr, len)
	local ranges = {}
	for i = 0, tonumber(len[0]) - 1 do
		ranges[#ranges + 1] = Range.wrap(ptr[i])
	end
	if ptr ~= nil then ffi.C.free(ptr) end
	return ranges
end

M.Tree = {}

local Parser = {}
Parser.__index = Parser

local function sourceFromInput(inputFn)
	local builder = {}
	local row = 0

	while true do
		local ok, text, offset = pcall(inputFn, 0, Point.new(row, 0))
		if not ok then
			error('error while executing read function: ' .. tostring(text))
		end
		if text == nil then break end
		if type(text) ~= 'string' then
			error('bad return value #1 from read function (string expected, got ' .. type(text) .. ')')
		end
		if offset ~= nil and type(offset) ~= 'number' then
			error('bad return value #2 from read function (integer expected, got ' .. type(offset) .. ')')
		end

		if offset then
			local len = #text
			if offset < 1 then offset = offset + len + 1 end
			if offset < 1 then offset = 1 end
			text = offset > len and '' or text:sub(offset)
		end

		builder[#builder + 1] = text
		row = row + 1
	end

	return table.concat(builder)
end

function Parser.new()
	local ptr = C.ts_parser_new()
	if ptr == nil then error('Could not create Tree-sitter parser') end
	return setmetatable({ _ptr = ffi.gc(ptr, C.ts_parser_delete) }, Parser)
end

function Parser:set_language(lang)
	return C.ts_parser_set_language(self._ptr, lang._ptr)
end

function Parser:parse(oldTree, inputFn)
	local oldPtr = oldTree and oldTree._ptr or nil
	local source = sourceFromInput(inputFn)
	local tree = C.ts_parser_parse_string(self._ptr, oldPtr, source, #source)
	return wrapTree(tree)
end

function Parser:parse_with(inputFn)
	return self:parse(nil, inputFn)
end

function Parser:parse_string(oldTree, source)
	local oldPtr = oldTree and oldTree._ptr or nil
	return wrapTree(C.ts_parser_parse_string(self._ptr, oldPtr, source, #source))
end

function Parser:reset()
	C.ts_parser_reset(self._ptr)
end

function Parser:set_included_ranges(ranges)
	if not ranges or #ranges == 0 then
		return C.ts_parser_set_included_ranges(self._ptr, nil, 0)
	end

	local cRanges = ffi.new('TSRange[?]', #ranges)
	for i, range in ipairs(ranges) do
		cRanges[i - 1] = crange(range)
	end
	return C.ts_parser_set_included_ranges(self._ptr, cRanges, #ranges)
end

function Parser:set_timeout_micros(timeout)
	if okSetTimeout then
		setTimeoutMicros(self._ptr, timeout)
		self._timeoutMicros = timeout
		return true
	end
	return false
end

function Parser:has_timeout()
	return okSetTimeout
end

M.Parser = { new = Parser.new }

local Language = {}
Language.__index = Language

local function symbolName(name)
	return 'tree_sitter_' .. name:gsub('%W', '_')
end

local declaredSymbols = {}

function Language.load(path, name)
	local ok, lib = pcall(ffi.load, path)
	if not ok then error('could not load dynamic library: ' .. tostring(lib)) end

	local sym = symbolName(name)
	if not declaredSymbols[sym] then
		ffi.cdef('const TSLanguage *' .. sym .. '(void);')
		declaredSymbols[sym] = true
	end

	local fn = lib[sym]
	if not fn then error('could not load symbol from dynamic library: ' .. sym) end

	local ptr = fn()
	local version
	if okLanguageAbiVersion then
		version = tonumber(languageAbiVersion(ptr))
	elseif okLanguageVersion then
		version = tonumber(languageVersion(ptr))
	end

	return setmetatable({
		_ptr = ptr,
		_lib = lib,
		path = path,
		name = name,
		version = version,
	}, Language)
end

M.Language = { load = Language.load }

local Query = {}
Query.__index = Query

local queryErrors = {
	[tonumber(ffi.C.TSQueryErrorSyntax)] = 'TSQueryErrorSyntax',
	[tonumber(ffi.C.TSQueryErrorNodeType)] = 'TSQueryErrorNodeType',
	[tonumber(ffi.C.TSQueryErrorField)] = 'TSQueryErrorField',
	[tonumber(ffi.C.TSQueryErrorCapture)] = 'TSQueryErrorCapture',
	[tonumber(ffi.C.TSQueryErrorStructure)] = 'TSQueryErrorStructure',
	[tonumber(ffi.C.TSQueryErrorLanguage)] = 'TSQueryErrorLanguage',
}

local function copyString(ptr, len)
	return ffi.string(ptr, tonumber(len))
end

function Query.new(lang, source)
	local offset = ffi.new('uint32_t[1]')
	local err = ffi.new('TSQueryError[1]')
	local ptr = C.ts_query_new(lang._ptr, source, #source, offset, err)
	if err[0] ~= ffi.C.TSQueryErrorNone then
		if err[0] == ffi.C.TSQueryErrorLanguage then
			error(string.format(
				'bad query: language ABI is incompatible with Tree-sitter runtime %s; language %s from %s reports ABI/version %s',
				tostring(M.runtime),
				tostring(lang.name),
				tostring(lang.path),
				tostring(lang.version or 'unknown')
			))
		end
		error(string.format('bad query: error type %s at byte offset %d',
			queryErrors[tonumber(err[0])] or tostring(err[0]),
			tonumber(offset[0])
		))
	end

	local self = setmetatable({ _ptr = ffi.gc(ptr, C.ts_query_delete), source = source }, Query)
	self._captureNames = {}
	self._stringValues = {}

	local len = ffi.new('uint32_t[1]')
	for i = 0, tonumber(C.ts_query_capture_count(ptr)) - 1 do
		self._captureNames[i] = copyString(C.ts_query_capture_name_for_id(ptr, i, len), len[0])
	end
	for i = 0, tonumber(C.ts_query_string_count(ptr)) - 1 do
		self._stringValues[i] = copyString(C.ts_query_string_value_for_id(ptr, i, len), len[0])
	end

	return self
end

function Query:disable_capture(name)
	C.ts_query_disable_capture(self._ptr, name, #name)
end

function Query:capture_name_for_id(id)
	return self._captureNames[tonumber(id)]
end

function Query:string_value_for_id(id)
	return self._stringValues[tonumber(id)]
end

M.Query = { new = Query.new }

local QueryCursor = {}
QueryCursor.__index = QueryCursor

local QueryCapture = {}
QueryCapture.__index = QueryCapture

local function wrapMatch(match, cursor)
	local captures = {}
	for i = 0, tonumber(match.capture_count) - 1 do
		local cap = match.captures[i]
		captures[#captures + 1] = {
			node = wrapNode(cap.node, cursor.node._tree),
			index = tonumber(cap.index),
		}
	end

	return {
		pattern_index = tonumber(match.pattern_index),
		capture_count = tonumber(match.capture_count),
		captures = captures,
		cursor = cursor,
	}
end

function QueryCursor.new(query, node)
	local ptr = C.ts_query_cursor_new()
	if ptr == nil then error('Could not create Tree-sitter query cursor') end

	local self = setmetatable({
		_ptr = ffi.gc(ptr, C.ts_query_cursor_delete),
		query = query,
		node = node,
	}, QueryCursor)
	C.ts_query_cursor_exec(self._ptr, query._ptr, node._node)
	return self
end

function QueryCursor:set_point_range(startPoint, endPoint)
	return C.ts_query_cursor_set_point_range(self._ptr, cpoint(startPoint), cpoint(endPoint))
end

function QueryCursor:next_match()
	local match = ffi.new('TSQueryMatch[1]')
	if not C.ts_query_cursor_next_match(self._ptr, match) then return nil end
	return wrapMatch(match[0], self)
end

function QueryCursor:next_capture()
	local match = ffi.new('TSQueryMatch[1]')
	local index = ffi.new('uint32_t[1]')
	if not C.ts_query_cursor_next_capture(self._ptr, match, index) then return nil end

	local wrapped = wrapMatch(match[0], self)
	local cap = wrapped.captures[tonumber(index[0]) + 1]
	return setmetatable({ _capture = cap, _match = wrapped }, QueryCapture)
end

function QueryCapture:node()
	return self._capture.node
end

function QueryCapture:index()
	return self._capture.index
end

function QueryCapture:name()
	return self._match.cursor.query:capture_name_for_id(self._capture.index)
end

local QuantifiedCapture = {}
QuantifiedCapture.__index = QuantifiedCapture

local quantifierNames = {
	[tonumber(ffi.C.TSQuantifierZero)] = 'Zero',
	[tonumber(ffi.C.TSQuantifierZeroOrOne)] = 'ZeroOrOne',
	[tonumber(ffi.C.TSQuantifierOne)] = 'One',
	[tonumber(ffi.C.TSQuantifierZeroOrMore)] = 'ZeroOrMore',
	[tonumber(ffi.C.TSQuantifierOneOrMore)] = 'OneOrMore',
}

function QuantifiedCapture:name()
	return self.match.cursor.query:capture_name_for_id(self.capture_id)
end

function QuantifiedCapture:quantifier()
	return quantifierNames[tonumber(self.quantifier)]
end

function QuantifiedCapture:one_node()
	if self.quantifier == ffi.C.TSQuantifierZero then return nil end
	for _, cap in ipairs(self.match.captures) do
		if cap.index == self.capture_id then
			return cap.node
		end
	end
	return nil
end

function QuantifiedCapture:id()
	return self.capture_id
end

function QuantifiedCapture:nodes()
	local nodes = {}
	for _, cap in ipairs(self.match.captures) do
		if cap.index == self.capture_id then
			nodes[#nodes + 1] = cap.node
		end
	end
	return nodes
end

local QueryRunner = {}
QueryRunner.__index = QueryRunner

function QueryRunner.new(predicates, directives, setup)
	if type(directives) == 'function' and setup == nil then
		setup = directives
		directives = nil
	end
	return setmetatable({
		predicates = predicates or {},
		directives = directives or {},
		setup = setup,
	}, QueryRunner)
end

local function runPredicates(runner, match)
	local query = match.cursor.query
	local count = ffi.new('uint32_t[1]')
	local steps = C.ts_query_predicates_for_pattern(query._ptr, match.pattern_index, count)
	local i = 0
	local metadata = {}

	if runner.setup then runner.setup() end

	while i < tonumber(count[0]) do
		local name = query:string_value_for_id(steps[i].value_id)
		i = i + 1

		local isPredicate = name:sub(-1) == '?'
		local fn = isPredicate and runner.predicates[name] or runner.directives[name]
		local args = {}
		while i < tonumber(count[0]) and steps[i].type ~= ffi.C.TSQueryPredicateStepTypeDone do
			local step = steps[i]
			if step.type == ffi.C.TSQueryPredicateStepTypeCapture then
				local captureId = tonumber(step.value_id)
				args[#args + 1] = setmetatable({
					capture_id = captureId,
					match = match,
					quantifier = C.ts_query_capture_quantifier_for_id(query._ptr, match.pattern_index, captureId),
				}, QuantifiedCapture)
			elseif step.type == ffi.C.TSQueryPredicateStepTypeString then
				args[#args + 1] = query:string_value_for_id(step.value_id)
			end
			i = i + 1
		end
		i = i + 1

		if not fn then
			if isPredicate then
				error("missing tree-sitter query predicate '#" .. tostring(name) .. "'")
			end
			goto continue
		end

		local ok, result
		if isPredicate then
			ok, result = pcall(fn, unpack(args))
		else
			ok, result = pcall(fn, metadata, unpack(args))
		end
		if not ok then
			error("error while executing query predicate/directive '#" .. tostring(name) .. "': " .. tostring(result))
		end
		if isPredicate and not result then return false, metadata end

		::continue::
	end

	return true, metadata
end

function QueryRunner:iter_captures(cursor)
	return function()
		while true do
			local match = ffi.new('TSQueryMatch[1]')
			local index = ffi.new('uint32_t[1]')
			if not C.ts_query_cursor_next_capture(cursor._ptr, match, index) then return nil end

			local wrapped = wrapMatch(match[0], cursor)
			local ok, metadata = runPredicates(self, wrapped)
			if ok then
				local cap = wrapped.captures[tonumber(index[0]) + 1]
				return setmetatable({ _capture = cap, _match = wrapped, metadata = metadata }, QueryCapture)
			end
		end
	end
end

function QueryRunner:iter_matches(cursor)
	return function()
		while true do
			local match = ffi.new('TSQueryMatch[1]')
			if not C.ts_query_cursor_next_match(cursor._ptr, match) then return nil end

			local wrapped = wrapMatch(match[0], cursor)
			local ok, metadata = runPredicates(self, wrapped)
			if ok then
				return wrapped, metadata
			end
		end
	end
end

M.Query.Cursor = { new = QueryCursor.new }
M.Query.Runner = { new = QueryRunner.new }

return M
