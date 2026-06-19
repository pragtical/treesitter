-- mod-version:3 --priority:200

local core = require 'core'
local command = require 'core.command'
local Doc = require 'core.doc'
local Highlight = require 'core.doc.highlighter'
local highlights = require 'plugins.treesitter.highlights'
local ts = require 'plugins.treesitter.tree_sitter'
require 'plugins.treesitter.style'


--- @class core.doc
--- @field treesit boolean
--- @field ts table

local oldDocNew = Doc.new
function Doc:new(filename, abs_filename, new_file)
	oldDocNew(self, filename, abs_filename, new_file)
	highlights.init(self)

	self.lenAccul = { #self.lines[1] }
	self.lenAcculIdx = 1
end

function Doc:invalidateLen(idx)
	if not idx or idx == 1 then
		self.lenAccul[1] = #self.lines[1]
		self.lenAcculIdx = 1
		return
	end

	if self.lenAcculIdx <= idx then return end

	self.lenAcculIdx = idx - 1
end

function Doc:lenLines(s, e)
	if e < s then return 0 end

	if self.lenAcculIdx < e then
		for i = self.lenAcculIdx + 1, e do
			self.lenAccul[i] = self.lenAccul[i - 1] + #self.lines[i]
		end

		self.lenAcculIdx = e
	end

	return s == 1 and self.lenAccul[e] or self.lenAccul[e] - self.lenAccul[s - 1]
end

local function reparse(doc)
	local root = doc.ts.root
	local function shouldAbort() return doc.ts.reparse end

	-- Parse the root tree and all injected sub-trees. If an edit lands while we
	-- are parsing, the parse aborts and we restart from the (already edited)
	-- root tree with a fresh source snapshot.
	local completed = false
	while not completed or doc.ts.reparse do
		doc.ts.reparse = false
		completed = root:parse(table.concat(doc.lines), shouldAbort)
	end

	doc.ts.tree = root.trees[1]
	doc.ts.source = nil
	doc.ts.running = false

	doc.highlighter:reset()
end

local oldDocInsert = Doc.raw_insert
function Doc:raw_insert(line, col, text, undo, time)
	oldDocInsert(self, line, col, text, undo, time)

	if self.treesit then
		self:invalidateLen(line)

		line, col = self:sanitize_position(line, col)

		local tsByte = self:lenLines(1, line - 1) + col - 1
		local tsLine, tsCol = line - 1, col - 1

		if self.ts.root.trees[1] then
			self.ts.root:edit(
				--[[start_byte   ]] tsByte,
				--[[old_end_byte ]] tsByte,
				--[[new_end_byte ]] tsByte + #text,
				--[[start_point  ]] ts.Point.new(tsLine, tsCol),
				--[[old_end_point]] ts.Point.new(tsLine, tsCol),
				--[[new_end_point]] ts.Point.new(tsLine, tsCol + #text)
			)
		end

		self.ts.reparse = true
		self.ts.source = nil
	end
end

local function sortPositions(line1, col1, line2, col2)
	if line1 > line2 or line1 == line2 and col1 > col2 then
		return line2, col2, line1, col1
	end
	return line1, col1, line2, col2
end

local oldDocRemove = Doc.raw_remove
function Doc:raw_remove(line1, col1, line2, col2, undo, time)
	if self.treesit then
		line1, col1 = self:sanitize_position(line1, col1)
		line2, col2 = self:sanitize_position(line2, col2)
		line1, col1, line2, col2 = sortPositions(line1, col1, line2, col2)

		local len = line1 == line2 and
			col2 - col1 or
			#self.lines[line1] - col1 + self:lenLines(line1 + 1, line2 - 1) + col2

		oldDocRemove(self, line1, col1, line2, col2, undo, time)
		self:invalidateLen(line1)

		local tsByte = self:lenLines(1, line1 - 1) + col1 - 1

		if self.ts.root.trees[1] then
			self.ts.root:edit(
				--[[start_byte   ]] tsByte,
				--[[old_end_byte ]] tsByte + len,
				--[[new_end_byte ]] tsByte,
				--[[start_point  ]] ts.Point.new(line1 - 1, col1 - 1),
				--[[old_end_point]] ts.Point.new(line2 - 1, col2 - 1),
				--[[new_end_point]] ts.Point.new(line1 - 1, col1 - 1)
			)
		end

		self.ts.reparse = true
		self.ts.source = nil
	else
		oldDocRemove(self, line1, col1, line2, col2, undo, time)
	end
end

local oldDocReload = Doc.reload
function Doc:reload()
	oldDocReload(self)

	if self.treesit then
		self:invalidateLen()
		self.ts.tree = nil
		self.ts.source = nil
		self.ts.reparse = true
		self.ts.running = false
		self.ts.root:reset()
	end
end

local oldStart = Highlight.start
function Highlight:start(...)
	local doc = self.doc

	if not doc.treesit then return oldStart(self, ...) end
	if not doc.ts.reparse then return end

	if not doc.ts.running then
		doc.ts.running = true

		core.add_thread(function()
			reparse(doc)
		end, doc)
	end
end

local oldTokenize = Highlight.tokenize_line
function Highlight:tokenize_line(idx, state)
	if not self.doc.treesit then return oldTokenize(self, idx, state) end
	if not self.doc.ts.tree then return oldTokenize(self, idx, state) end
	
	local txt      = self.doc.lines[idx]
	local row      = idx - 1
	local toks     = {}
	local buf      = { 'normal', #txt }
	local startBuf = 0
	state = state or string.char(0)

	-- Collect captures from the root tree and every injected sub-tree covering
	-- this row. The FFI node wrappers alias the cursor's transient capture
	-- buffer, so we must read each node's data immediately, before the iterator
	-- advances; storing the capture objects to inspect later is not safe.
	local captures = {}
	self.doc.ts.root:forEachHighlightTree(row, function(langTree, tree)
		local cursor = ts.Query.Cursor.new(langTree.query, tree:root_node())
		cursor:set_point_range(ts.Point.new(row, 0), ts.Point.new(row, #txt - 1))

		for capture in langTree.runner:iter_captures(cursor) do
			local node = capture:node()
			local startPt, endPt = node:start_point(), node:end_point()
			captures[#captures + 1] = {
				name = capture:name(),
				order = #captures + 1,
				level = langTree.level,
				startByte = node:start_byte(),
				endByte = node:end_byte(),
				startRow = startPt:row(),
				startCol = startPt:column(),
				endRow = endPt:row(),
				endCol = endPt:column(),
			}
		end
	end)

	table.sort(captures, function(a, b)
		if a.startByte ~= b.startByte then return a.startByte < b.startByte end
		if a.endByte ~= b.endByte then return a.endByte > b.endByte end
		-- Same span: apply deeper (injected) captures last so they win.
		if a.level ~= b.level then return a.level < b.level end
		return a.order < b.order
	end)

	for _, capture in ipairs(captures) do
		local name = capture.name

		if name:find('_', 1, true) then goto continue end

		if row > capture.endRow then goto continue end
		if row < capture.startRow then break end

		local startPos = capture.startRow < row and 1 or capture.startCol + 1
		local endPos   = capture.endRow > row and #txt or capture.endCol

		local i = #buf - 1
		while i >= 1 and buf[i + 1] < startPos do
			local e = buf[i + 1]
			toks[#toks + 1] = buf[i]
			toks[#toks + 1] = txt:sub(startBuf, e)
			startBuf = e + 1

			buf[i], buf[i + 1] = nil, nil
			i = i - 2
		end

		toks[#toks + 1] = buf[i]
		toks[#toks + 1] = txt:sub(startBuf, startPos - 1)
		startBuf = startPos

		buf[#buf + 1] = name
		buf[#buf + 1] = endPos

		::continue::
	end

	local i = #buf - 1
	for i = #buf - 1, 1, -2 do
		local e = buf[i + 1]
		toks[#toks + 1] = buf[i]
		toks[#toks + 1] = txt:sub(startBuf, e)
		startBuf = e + 1

		i = i - 2
	end
	
	return {
		init_state = state,
		state      = state,
		text       = txt,
		tokens     = toks
	}
end

command.add('core.docview!', {
	['treesitter:toggle-highlighting'] = function(dv)
		-- check for doc.ts to not toggle on docviews that are in unsupported languages
		if dv.doc.ts then
			dv.doc.treesit = not dv.doc.treesit
			dv.doc.highlighter:reset()
			dv.doc:invalidateLen()
		end
	end
})
