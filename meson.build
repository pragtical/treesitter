project('treesitter',
    ['c'],
    version : '0.4.0',
    license : 'MIT',
    meson_version : '>= 0.56',
    default_options : ['c_std=c11']
)

if get_option('arch_tuple') != ''
    arch_tuple = get_option('arch_tuple')
else
    arch_tuple = '@0@-@1@'.format(target_machine.cpu_family(), target_machine.system())
endif

data_dir = get_option('data_dir')

subproject('tree-sitter', default_options: [
    'arch_tuple=' + arch_tuple,
    'data_dir=' + data_dir,
])

install_data(
    'plugins/treesitter/config.lua',
    'plugins/treesitter/highlights.lua',
    'plugins/treesitter/init.lua',
    'plugins/treesitter/languages.lua',
    'plugins/treesitter/style.lua',
    'plugins/treesitter/tree_sitter.lua',
    'plugins/treesitter/util.lua',
    install_dir: join_paths(data_dir, 'plugins', 'treesitter')
)
