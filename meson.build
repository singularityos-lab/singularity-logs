project('singularity-logs', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-logs"', language: 'c')
subdir('po')

gtk_dep   = dependency('gtk4')
gee_dep   = dependency('gee-0.8')
json_dep  = dependency('json-glib-1.0')
posix_dep = meson.get_compiler('vala').find_library('posix')

systemd_dep = dependency('libsystemd', required: false)
journal_deps = []
if systemd_dep.found() and meson.get_compiler('c').has_function('sd_journal_open',
    dependencies: systemd_dep, prefix: '#include <systemd/sd-journal.h>')
  journal_deps = [systemd_dep]
  add_project_arguments('-D', 'HAVE_SD_JOURNAL', '--vapidir', meson.current_source_dir() / 'vapi', language: 'vala')
endif

core_dep = dependency('sinty-system-1', required: false)
core_deps = []
if core_dep.found() and meson.get_compiler('c').has_function('sinty_logs_sealed',
    dependencies: core_dep, prefix: '#include <sinty-system/v1.h>')
  core_deps = [core_dep]
  add_project_arguments('-D', 'HAVE_SINTY_CORE', '--vapidir', meson.current_source_dir() / 'vapi', '--pkg', 'sinty-system-1', language: 'vala')
endif

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

gnome = import('gnome')

resources = gnome.compile_resources(
  'singularity-logs-resources',
  'resources/dev.sinty.logs.gresource.xml',
  source_dir: meson.current_source_dir() / 'data' / 'icons',
)

executable('singularity-logs',
  files('src/sources.vala', 'src/window.vala', 'src/search.vala', 'src/app.vala') + [resources],
  dependencies: [gtk_dep, gee_dep, json_dep, posix_dep, libsingularity_dep] + journal_deps + core_deps,
  install: true
)

shared_module('singularity-logs-widget',
  files('src/sources.vala', 'widget/errors_widget.vala'),
  dependencies: [gtk_dep, gee_dep, json_dep, posix_dep, dependency('gio-unix-2.0'), libsingularity_dep] + journal_deps + core_deps,
  install: true,
  install_dir: get_option('libdir') / 'singularity' / 'widgets'
)

install_data('widget/dev.sinty.logs.recent-errors.widget',
  install_dir: get_option('datadir') / 'singularity' / 'widgets'
)

install_data('data/dev.sinty.logs.search-provider.ini',
  install_dir: get_option('datadir') / 'singularity' / 'search-providers',
  rename: 'dev.sinty.logs.ini'
)

service_conf = configuration_data()
service_conf.set('bindir', get_option('prefix') / get_option('bindir'))
configure_file(
  input: 'data/dev.sinty.logs.service.in',
  output: 'dev.sinty.logs.service',
  configuration: service_conf,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)

sources_test = executable('logs-test',
  files('src/sources.vala', 'tests/sources_test.vala'),
  dependencies: [gee_dep, json_dep, posix_dep, dependency('gio-2.0')] + journal_deps + core_deps,
)
test('logs', sources_test, env: ['SEALED_DATA=' + meson.current_source_dir() / 'tests' / 'data' / 'sealed'])

install_data('data/dev.sinty.logs.desktop',
  install_dir: get_option('datadir') / 'applications'
)

install_data('data/icons/dev.sinty.logs.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)
