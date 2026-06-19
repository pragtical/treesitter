local core = require 'core'
local style = require 'core.style'

local config = require 'plugins.treesitter.config'

-- Capture -> base color fallbacks. These mirror Pragtical core's
-- `map_new_syntax_colors` (data/core/init.lua) so the plugin and core agree on
-- every shared capture. Core's map runs first and wins shared names, so an entry
-- that disagreed here would be silently overridden; keeping them aligned makes
-- this table reflect what is actually shown and a correct standalone fallback.
local fallbackMap = {
	['normal'] = {
		'punctuation.bracket',
		['variable'] = {
			['variable.parameter'] = {
				'variable.parameter.builtin',
			},
			'variable.member',
		},
	},
	['symbol'] = {
		'property',
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
		['attribute'] = {
			'attribute.builtin',
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
		'tag.builtin',
		'tag.attribute',
	},
	['keyword2'] = {
		['module'] = {
			'module.builtin',
		},
		['type'] = {
			'type.builtin',
			'type.definition',
		},
		'variable.builtin',
		'markup.strong',
		'markup.italic',
		'markup.strikethrough',
		'markup.underline',
	},
	['number'] = {
		'number.float',
		['constant'] = {
			'constant.builtin',
			'constant.macro',
		},
		['markup.list'] = {
			'markup.list.checked',
			'markup.list.unchecked',
		},
	},
	['literal'] = {
		'boolean',
	},
	['string'] = {
		'string.regexp',
		['string.special'] = {
			'string.special.symbol',
			'string.special.path',
			'string.special.url',
		},
		['character'] = {
			'character.constant',
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
		'punctuation.delimiter',
		'punctuation.special',
		'tag.delimiter',
	},
	['function'] = {
		'function.builtin',
		'function.call',
		'function.macro',
		['function.method'] = {
			'function.method.call',
		},
		'tag',
		'label',
		'constructor',
		['markup.link'] = {
			'markup.link.label',
		},
	},
}

local function setFallbacks(fallbackMap, colour, missing)
	missing = missing or {}

	if not config.useFallbackColors then return {} end

	for k, v in pairs(fallbackMap) do
		local name = type(k) == 'string' and k or v

		-- rawget so a capture that only resolves through core's syntax metatable
		-- (e.g. markup.link.url inheriting markup.link) still gets this map's
		-- explicit color instead of a different parent's. Only *report* it as a
		-- fallback when the theme/core can't resolve it at all; captures that
		-- merely inherit a base color via the metatable are fine and would
		-- otherwise flood the warning with dozens of already-colored names.
		if not rawget(style.syntax, name) then
			if not style.syntax[name] then
				missing[#missing + 1] = name
			end
			style.syntax[name] = colour
		end

		if type(k) == 'string' then
			setFallbacks(v, rawget(style.syntax, name), missing)
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
