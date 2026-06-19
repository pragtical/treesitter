local config = require 'plugins.treesitter.config'
local languages = require 'plugins.treesitter.languages'
local ts = require 'plugins.treesitter.tree_sitter'

local M = {}

local disabledCaptures = {
	'spell',
	'nospell',
	-- Neovim rendering hint to hide markers (e.g. the ** around bold text or the
	-- backticks around code). Pragtical does not conceal, so dropping the capture
	-- lets the markers keep their surrounding emphasis/code color instead of
	-- rendering uncolored on top of it.
	'conceal',
	-- Neovim "no highlight" marker used by injected languages (e.g. phpdoc
	-- description text) to opt out of highlighting. Dropping it lets the text
	-- fall through to the surrounding capture, such as the parent @comment,
	-- instead of rendering as uncolored normal text on top of it.
	'none',
}

local warnedTimeoutRuntime = false
local warnedInjectionLangs = {}

local function pointToByte(doc, row, col)
	return row == 0 and col or doc:lenLines(1, row) + col
end

local function rangeToTs(range)
	return ts.Range.new(
		ts.Point.new(range[1], range[2]),
		ts.Point.new(range[4], range[5]),
		range[3],
		range[6]
	)
end

local function rangeIntersectsRow(range, row)
	return range[1] <= row and row <= range[4]
end

local function rangeIntersects(a, b)
	if a[4] < b[1] or a[4] == b[1] and a[5] <= b[2] then return false end
	if a[1] > b[4] or a[1] == b[4] and a[2] >= b[5] then return false end
	return true
end

local function rangeIntersection(a, b)
	if not rangeIntersects(a, b) then return nil end
	local s = b
	if a[1] > b[1] or a[1] == b[1] and a[2] > b[2] then s = a end
	local e = b
	if a[4] < b[4] or a[4] == b[4] and a[5] < b[5] then e = a end
	return { s[1], s[2], s[3], e[4], e[5], e[6] }
end

local function clipRanges(ranges, parentRanges)
	if not parentRanges then return ranges end

	local clipped = {}
	for _, range in ipairs(ranges) do
		for _, parent in ipairs(parentRanges) do
			local intersection = rangeIntersection(range, parent)
			if intersection then clipped[#clipped + 1] = intersection end
		end
	end
	return clipped
end

local function metadataRange(doc, node, metadata)
	local startPt = node:start_point()
	local endPt = node:end_point()
	local sr, sc = startPt:row(), startPt:column()
	local er, ec = endPt:row(), endPt:column()

	if metadata then
		if metadata.range then
			sr, sc, er, ec = metadata.range[1], metadata.range[2], metadata.range[3], metadata.range[4]
		end
		if metadata.offset then
			sr = sr + metadata.offset[1]
			sc = sc + metadata.offset[2]
			er = er + metadata.offset[3]
			ec = ec + metadata.offset[4]
		end
	end

	return { sr, sc, pointToByte(doc, sr, sc), er, ec, pointToByte(doc, er, ec) }
end

local function nodeRanges(doc, node, metadata, includeChildren)
	local range = metadataRange(doc, node, metadata)
	if includeChildren or node:named_child_count() == 0 then
		return { range }
	end

	local ranges = {}
	local sr, sc, sb, er, ec, eb = range[1], range[2], range[3], range[4], range[5], range[6]
	for i = 0, node:named_child_count() - 1 do
		local child = node:named_child(i)
		local childRange = metadataRange(doc, child)
		if childRange[1] > sr or childRange[1] == sr and childRange[2] > sc then
			ranges[#ranges + 1] = { sr, sc, sb, childRange[1], childRange[2], childRange[3] }
		end
		sr, sc, sb = childRange[4], childRange[5], childRange[6]
	end

	if er > sr or er == sr and ec > sc then
		ranges[#ranges + 1] = { sr, sc, sb, er, ec, eb }
	end
	return ranges
end

local function nodeText(doc, node, metadata)
	if metadata and metadata.text then return metadata.text end
	local range = metadataRange(doc, node, metadata)
	return doc:get_text(range[1] + 1, range[2] + 1, range[4] + 1, range[5] + 1)
end

local function predicatesAndDirectivesFor(doc)
	local function getSource(n, metadata)
		if type(n) == 'string' then return n end
		if not n then return '' end

		local node = n.one_node and n:one_node() or n
		if not node then return '' end

		if metadata and metadata.text then return metadata.text end

		return nodeText(doc, node, metadata)
	end

	local function coerceToStr(n)
		return type(n) == 'string' and n or getSource(n:one_node())
	end

	local predicates = {
		['eq?'] = function(ns, m)
			local str = coerceToStr(m)
			for _, n in ipairs(ns:nodes()) do
				if getSource(n) ~= str then return false end
			end
			return true
		end,

		['any-eq?'] = function(ns, m)
			local str = coerceToStr(m)
			for _, n in ipairs(ns:nodes()) do
				if getSource(n) == str then return true end
			end
			return false
		end,

		['match?'] = function(ns, s)
			local r = regex.compile(s)
			for _, n in ipairs(ns:nodes()) do
				if not r:cmatch(getSource(n), 0, 0) then return false end
			end
			return true
		end,

		['any-match?'] = function(ns, s)
			local r = regex.compile(s)
			for _, n in ipairs(ns:nodes()) do
				if r:cmatch(getSource(n), 0, 0) then return true end
			end
			return false
		end,

		['lua-match?'] = function(ns, p)
			for _, n in ipairs(ns:nodes()) do
				if not getSource(n):match(p) then return false end
			end
			return true
		end,

		['any-lua-match?'] = function(ns, p)
			for _, n in ipairs(ns:nodes()) do
				if getSource(n):match(p) then return true end
			end
			return false
		end,

		['contains?'] = function(ns, ...)
			local parts = {...}
			for _, n in ipairs(ns:nodes()) do
				local s = getSource(n)
				for _, part in ipairs(parts) do
					if not s:find(part, 1, true) then return false end
				end
			end
			return true
		end,

		['any-contains?'] = function(ns, ...)
			local parts = {...}
			for _, n in ipairs(ns:nodes()) do
				local s = getSource(n)
				for _, part in ipairs(parts) do
					if s:find(part, 1, true) then return true end
				end
			end
			return false
		end,

		['any-of?'] = function(ns, ...)
			local values = {}
			for _, value in ipairs {...} do values[value] = true end
			for _, n in ipairs(ns:nodes()) do
				if not values[getSource(n)] then return false end
			end
			return true
		end,

		['has-ancestor?'] = function(n, ...)
			local types = {}
			for _, t in ipairs {...} do types[t] = true end
			local a = n:one_node():parent()
			while a do
				if types[a:type()] then return true end
				a = a:parent()
			end
			return false
		end,

		['has-parent?'] = function(n, ...)
			local p = n:one_node():parent()
			if not p then return false end
			p = p:type()
			for _, t in ipairs {...} do
				if p == t then return true end
			end
			return false
		end,
	}

	local ret = {}
	for name, fn in pairs(predicates) do
		ret[name] = fn
		if name:sub(-1) == '?' then
			ret['not-' .. name] = function(...)
				return not fn(...)
			end
		end
	end

	local directives = {
		['set!'] = function(metadata, ...)
			local args = {...}
			if type(args[1]) == 'table' and args[1].id then
				local id = args[1]:id()
				metadata[id] = metadata[id] or {}
				local key = args[2]
				local value = args[3]
				if type(value) == 'table' and value.one_node then
					value = getSource(value:one_node(), metadata[value:id()])
				end
				metadata[id][key] = value or true
			else
				metadata[args[1]] = args[2] or true
			end
		end,

		['offset!'] = function(metadata, capture, sr, sc, er, ec)
			local id = capture:id()
			metadata[id] = metadata[id] or {}
			metadata[id].offset = {
				tonumber(sr) or 0,
				tonumber(sc) or 0,
				tonumber(er) or 0,
				tonumber(ec) or 0,
			}
		end,

		['gsub!'] = function(metadata, capture, pattern, replacement)
			local id = capture:id()
			metadata[id] = metadata[id] or {}
			metadata[id].text = getSource(capture:one_node(), metadata[id]):gsub(pattern, replacement)
		end,

		['trim!'] = function(metadata, capture, trimStartLines, trimStartCols, trimEndLines, trimEndCols)
			local id = capture:id()
			local node = capture:one_node()
			if not node then return end

			local text = getSource(node)
			local lines = {}
			for line in (text .. '\n'):gmatch('(.-)\n') do
				lines[#lines + 1] = line
			end

			local range = metadataRange(doc, node, metadata[id])
			local sr, sc, er, ec = range[1], range[2], range[4], range[5]
			local first, last = 1, #lines

			if trimEndLines == '1' or trimEndLines == nil then
				while last > 0 and lines[last]:match('^%s*$') do
					last = last - 1
					er = er - 1
					ec = last > 0 and #lines[last] or 0
				end
			end
			if trimEndCols == '1' and lines[last] then
				local s = lines[last]:find('%s*$') or (#lines[last] + 1)
				ec = s - 1 + (last == 1 and sc or 0)
			end
			if trimStartLines == '1' then
				while first <= last and lines[first]:match('^%s*$') do
					first = first + 1
					sr = sr + 1
					sc = 0
				end
			end
			if trimStartCols == '1' and lines[first] then
				local _, e = lines[first]:find('^%s*')
				sc = (first == 1 and sc or 0) + (e or 0)
			end

			if sr < er or sr == er and sc <= ec then
				metadata[id] = metadata[id] or {}
				metadata[id].range = { sr, sc, er, ec }
			end
		end,
	}

	return ret, directives
end

local LanguageTree = {}
LanguageTree.__index = LanguageTree

local function compileQuery(def, lang, queryType)
	local queryStr = languages.getQuery(def, queryType)
	if not queryStr then return nil end
	local query = ts.Query.new(lang, queryStr)
	if queryType == 'highlights' then
		for _, name in ipairs(disabledCaptures) do
			query:disable_capture(name)
		end
	end
	return query
end

-- Background parsing is sliced so the editor stays responsive even when an
-- injection-heavy document spawns many small parses that never individually
-- hit the parser timeout. nextYield is reset at the start of each root parse.
local YIELD_INTERVAL = 1 / 120
local nextYield = 0

local function sliceYield(shouldAbort)
	if system.get_time() >= nextYield then
		coroutine.yield(0)
		nextYield = system.get_time() + YIELD_INTERVAL
		if shouldAbort and shouldAbort() then return false end
	end
	return true
end

local function regionBounds(region)
	local minRow, maxRow = math.huge, -1
	for _, range in ipairs(region) do
		if range[1] < minRow then minRow = range[1] end
		if range[4] > maxRow then maxRow = range[4] end
	end
	return { minRow, maxRow }
end

function LanguageTree.new(doc, def, parent, level)
	local lang = languages.getLang(def)
	if not lang then return nil end

	local parser = ts.Parser.new()
	parser:set_language(lang)
	if not parser:set_timeout_micros(config.maxParseTime) then
		if not warnedTimeoutRuntime then
			core.warn(
			'Treesitter runtime %s does not support parse timeouts. \z
			Install or configure the bundled Treesitter runtime to avoid blocking syntax parsing.',
				ts.runtime
			)
			warnedTimeoutRuntime = true
		end
		return nil
	end

	local predicates, directives = predicatesAndDirectivesFor(doc)
	return setmetatable({
		doc = doc,
		def = def,
		parent = parent,
		level = level or 0,
		parser = parser,
		-- One tree per injected region. The root has a single whole-document
		-- tree at index 1. regions[i]/bounds[i] are parallel to trees[i].
		trees = {},
		regions = nil,
		bounds = nil,
		children = {},
		query = compileQuery(def, lang, 'highlights'),
		injectionQuery = compileQuery(def, lang, 'injections'),
		runner = ts.Query.Runner.new(predicates, directives),
	}, LanguageTree)
end

function LanguageTree:reset()
	self.trees = {}
	self.children = {}
	self.parser:reset()
end

function LanguageTree:edit(...)
	-- Only the root tree is edited incrementally. Injected children are rebuilt
	-- from scratch on the next reparse, so their stale trees are dropped here.
	if self.trees[1] then self.trees[1]:edit(...) end
	self.children = {}
	self.parser:reset()
end

--- Parse this language's region(s), then recurse into injected children.
--- Returns true on completion, false if a pending edit aborted the parse.
--- Must run inside a core thread: it yields while parsing is time-sliced.
function LanguageTree:parse(source, shouldAbort)
	if self.level == 0 then
		nextYield = system.get_time() + YIELD_INTERVAL
	end

	local count = self.regions and #self.regions or 1

	-- Drop trees for regions that no longer exist after re-collection.
	for i = #self.trees, count + 1, -1 do
		self.trees[i] = nil
	end

	for i = 1, count do
		local region = self.regions and self.regions[i]
		if region then
			local ranges = {}
			for _, range in ipairs(region) do
				ranges[#ranges + 1] = rangeToTs(range)
			end
			self.parser:set_included_ranges(ranges)
		else
			self.parser:set_included_ranges(nil)
		end

		local newTree = self.parser:parse_string(self.trees[i], source)
		while not newTree do
			coroutine.yield(0)
			if shouldAbort and shouldAbort() then return false end
			newTree = self.parser:parse_string(self.trees[i], source)
		end
		self.trees[i] = newTree

		if not sliceYield(shouldAbort) then return false end
	end

	if self.injectionQuery then
		self:syncChildren(self:collectInjections())
		for _, child in pairs(self.children) do
			if not child:parse(source, shouldAbort) then return false end
		end
	end

	return true
end

local function resolveInjectionLang(lang)
	return languages.resolveLang(lang)
end

local function addInjection(target, langName, pattern, combined, ranges, parentRegion)
	ranges = clipRanges(ranges, parentRegion)
	if #ranges == 0 then return end

	local entry = target[langName]
	if not entry then entry = {}; target[langName] = entry end

	if not combined then
		-- Each non-combined match becomes its own region (and its own tree) so
		-- that, e.g., two separate code fences never share parser state.
		entry[#entry + 1] = ranges
		return
	end

	-- Combined injections of the same pattern merge into a single region.
	local key = 'combined:' .. tostring(pattern)
	local region = entry[key]
	if not region then region = {}; entry[key] = region end
	for _, range in ipairs(ranges) do
		region[#region + 1] = range
	end
end

function LanguageTree:collectInjections()
	local injections = {}
	for i, tree in ipairs(self.trees) do
		if tree then
			local region = self.regions and self.regions[i]
			local cursor = ts.Query.Cursor.new(self.injectionQuery, tree:root_node())
			for match, metadata in self.runner:iter_matches(cursor) do
				local langName, combined, ranges = self:extractInjection(match, metadata)
				if langName and #ranges > 0 then
					addInjection(injections, langName, match.pattern_index, combined, ranges, region)
				end
			end
		end
	end
	return injections
end

function LanguageTree:syncChildren(injections)
	local children = {}
	for langName, entry in pairs(injections) do
		local def = languages.defs[langName]
		if def then
			local child = self.children[langName]
				or LanguageTree.new(self.doc, def, self, self.level + 1)
			if child then
				local regions, bounds = {}, {}
				for _, region in pairs(entry) do
					regions[#regions + 1] = region
					bounds[#bounds + 1] = regionBounds(region)
				end
				child.regions = regions
				child.bounds = bounds
				children[langName] = child
			elseif not warnedInjectionLangs[langName] then
				core.warn('Could not initialize Treesitter injected language %s', langName)
				warnedInjectionLangs[langName] = true
			end
		end
	end
	self.children = children
end

function LanguageTree:extractInjection(match, metadata)
	local query = self.injectionQuery
	local combined = metadata['injection.combined'] ~= nil
	local langName = metadata['injection.self'] and self.def.name
	local parentDef = self.parent and self.parent.def
	if not langName and metadata['injection.parent'] and parentDef then
		langName = parentDef.name
	end
	if not langName and metadata['injection.language'] then
		langName = resolveInjectionLang(metadata['injection.language'])
	end

	local includeChildren = metadata['injection.include-children'] ~= nil
	local ranges = {}

	for _, cap in ipairs(match.captures) do
		local name = query:capture_name_for_id(cap.index)
		local node = cap.node
		local capMetadata = metadata[cap.index]

		if name == 'injection.language' then
			langName = resolveInjectionLang(nodeText(self.doc, node, capMetadata))
		elseif name == 'injection.filename' then
			local filename = nodeText(self.doc, node, capMetadata)
			local def = languages.findDef(filename)
			langName = def and def.name or langName
		elseif name == 'injection.content' then
			for _, range in ipairs(nodeRanges(self.doc, node, capMetadata, includeChildren)) do
				ranges[#ranges + 1] = range
			end
		end
	end

	return langName, combined, ranges
end

--- Invoke fn(languageTree, tree) for every highlight tree covering `row`.
function LanguageTree:forEachHighlightTree(row, fn)
	if self.query then
		for i, tree in ipairs(self.trees) do
			if tree then
				local bound = self.bounds and self.bounds[i]
				if not bound or (row >= bound[1] and row <= bound[2]) then
					fn(self, tree)
				end
			end
		end
	end
	for _, child in pairs(self.children) do
		child:forEachHighlightTree(row, fn)
	end
end

--- @param doc core.doc
function M.init(doc)
	if not doc.filename then return end

	local langDef = languages.findDef(doc.abs_filename)
	if not langDef then return end

	local tree = LanguageTree.new(doc, langDef)
	if not tree or not tree.query then return end

	doc.treesit = true
	doc.ts = {
		parser = tree.parser,
		tree = nil,
		reparse = true,
		running = false,
		root = tree,
		query = tree.query,
		runner = tree.runner,
	}
end

return M
