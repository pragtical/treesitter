local core = require 'core'
local style = require 'core.style'

local config = require 'plugins.treesitter.config'

local fallbackMap = {
	['normal'] = {
		'punctuation.delimiter',
		['punctuation.bracket'] = {
			'tag.delimiter',
		},
	},
	['symbol'] = {
		['variable'] = {
			'variable.builtin',
			['variable.parameter'] = {
				'variable.parameter.builtin',
			},
			['variable.member'] = {
				'property',
				'tag.attribute',
			},
		},
		'label',
	},
	['comment'] = {
		'string.documentation',
		'comment.documentation',
		'comment.error',
		'comment.warning',
		'comment.todo',
		'comment.note',
	},
	['keyword'] = {
		['markup.heading'] = {
			'markup.heading.1',
			'markup.heading.2',
			'markup.heading.3',
			'markup.heading.4',
			'markup.heading.5',
			'markup.heading.6',
		},
		'string.escape',
		'keyword.coroutine',
		'keyword.function',
		'keyword.import',
		'keyword.type',
		'keyword.modifier',
		'keyword.repeat',
		'keyword.return',
		'keyword.debug',
		'keyword.exception',
		'keyword.conditional',
		['keyword.directive'] = {
			'keyword.directive.define',
		},
		'punctuation.special',
		'tag.builtin',
	},
	['keyword2'] = {
		['module'] = {
			'module.builtin',
		},
		['type'] = {
			'type.builtin',
			'type.definition',
		},
		'constructor',
		'markup.strong',
		'markup.italic',
		'markup.strikethrough',
		'markup.underline',
	},
	['number'] = {
		'number.float',
		['markup.list'] = {
			'markup.list.checked',
			'markup.list.unchecked',
		},
	},
	['literal'] = {
		['constant'] = {
			'constant.builtin',
			'constant.macro',
		},
		['character'] = {
			'character.constant',
		},
		'boolean',
	},
	['string'] = {
		'string.regexp',
		['string.special'] = {
			'string.special.symbol',
			'string.special.path',
			'string.special.url',
		},
		'markup.quote',
		'markup.math',
		'markup.link.url',
		['markup.raw'] = {
			'markup.raw.block',
		},
	},
	['operator'] = {
		'keyword.operator',
		'keyword.conditional.ternary',
	},
	['function'] = {
		['attribute'] = {
			'attribute.builtin',
		},
		'function.builtin',
		'function.call',
		'function.macro',
		['function.method'] = {
			'function.method.call',
		},
		'tag',
		['markup.link'] = {
			'markup.link.label',
		},
	},
}

local function setFallbacks(fallbackMap, colour, missing)
	missing = missing or {}

	if not config.useFallbackColors then return {} end

	for k, v in pairs(fallbackMap) do
		-- Use rawget so a capture that only resolves through core's syntax
		-- inheritance metatable (e.g. markup.link.url falling back to
		-- markup.link) is still treated as unset and gets this map's explicit
		-- color, rather than silently inheriting a different parent.
		if type(k) == 'string' then
			if not rawget(style.syntax, k) then
				style.syntax[k] = colour
				missing[#missing + 1] = k
			end

			setFallbacks(v, rawget(style.syntax, k), missing)
		else
			if not rawget(style.syntax, v) then
				style.syntax[v] = colour
				missing[#missing + 1] = v
			end
		end
	end

	return missing
end

local function refreshSyntaxColors()
	local missing = setFallbacks(fallbackMap)

	if config.warnFallbackColors and #missing > 0 then
		table.sort(missing)

		core.warn(string.format(
			'Fallbacks were used for %d colors for Tree-sitter highlighting.\n\z
			Disable this message by setting the warnFallbackColors option \z
			in the module plugins.treesitter.config to false, \z
			or by specifying all the following syntax colors: \n\t%s',
			#missing, table.concat(missing, '\n\t')
		))
	end
end

local oldReloadModule = core.reload_module
function core.reload_module(name)
	if name:find('colors.', 1, true) then
		style.syntax = {}
		oldReloadModule(name)
		refreshSyntaxColors(fallbackMap)
	else
		oldReloadModule(name)
	end
end

core.add_thread(refreshSyntaxColors)
