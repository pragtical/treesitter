local common = require 'core.common'
local config = require 'core.config'

local defaults = {
	useFallbackColors = true,
	warnFallbackColors = true,
	maxParseTime = 2000,
	treeSitterRuntimePath = os.getenv('TREESITTER_RUNTIME'),
}

local spec = {
	name = 'Treesitter',
	{
		label       = 'Use fallback colors',
		description = 'Set fallbacks for missing colors',
		path        = 'useFallbackColors',
		type        = 'toggle',
	},
	{
		label       = 'Warn fallback colors',
		description = 'Warn when fallback colors are used',
		path        = 'warnFallbackColors',
		type        = 'toggle',
	},
	{
		label       = 'The below options are meant for advanced use only.',
		path        = '',
		type        = 'button',
		icon        = '!',
	},
	{
		label       = 'Maximum parse time',
		description = 'Maximum time spent parsing before deferring it (in µs). Set this to 0 to disable deferring',
		path        = 'maxParseTime',
		type        = 'number',
		min         = 0,
		step        = 1,
	},
	{
		label       = 'Tree-sitter runtime path',
		description = 'Optional path to a Tree-sitter runtime library. Bundled runtimes are tried before system libraries when this is unset.',
		path        = 'treeSitterRuntimePath',
		type        = 'text',
	},
}

for _, option in ipairs(spec) do
	option.default = defaults[option.path]
end

defaults.config_spec      = spec
config.plugins.treesitter = common.merge(defaults, config.plugins.treesitter)

return config.plugins.treesitter
