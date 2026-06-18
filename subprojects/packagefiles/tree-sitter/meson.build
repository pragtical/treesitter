project('tree-sitter',
    ['c'],
    version : 'GIT',
    license : 'MIT',
    meson_version : '>= 0.56',
    default_options : ['c_std=c11']
)

if get_option('arch_tuple') != ''
    arch_tuple = get_option('arch_tuple')
else
    arch_tuple = '@0@-@1@'.format(target_machine.cpu_family(), target_machine.system())
endif

library_suffix = []
if host_machine.system() == 'darwin'
    library_suffix = 'so'
endif

tree_sitter = shared_library('tree-sitter.' + arch_tuple,
    [
        'lib/src/alloc.c',
        'lib/src/get_changed_ranges.c',
        'lib/src/language.c',
        'lib/src/lexer.c',
        'lib/src/node.c',
        'lib/src/parser.c',
        'lib/src/query.c',
        'lib/src/stack.c',
        'lib/src/subtree.c',
        'lib/src/tree.c',
        'lib/src/tree_cursor.c',
        'lib/src/wasm_store.c',
    ],
    name_prefix: '',
    name_suffix: library_suffix,
    include_directories: [
        include_directories('lib/src'),
        include_directories('lib/include'),
    ],
    c_args: host_machine.system() == 'windows' ? [] : [
        '-D_DEFAULT_SOURCE',
        '-D_POSIX_C_SOURCE=200809L',
    ],
    install_dir: join_paths(get_option('data_dir'), 'plugins', 'treesitter'),
    install: true
)

tree_sitter_dep = declare_dependency(
    link_with: tree_sitter,
    include_directories: include_directories('lib/include')
)
