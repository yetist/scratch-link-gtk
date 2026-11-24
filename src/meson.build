sources = files(
  'main.vala',
  'settings.vala',
  'application.vala',
  'link-service.vala',
  'protocol/json-rpc.vala',
  'protocol/uri.vala',
  'protocol/session.vala',
  'protocol/session-manager.vala',
  'protocol/websocket-server.vala',
  'ble/gatt-uuid.vala',
  'ble/gatt-policy.vala',
  'ble/byte-encoding.vala',
  'ble/scan-filter.vala',
  'ble/ble-session.vala',
  'bluez/bluez-types.vala',
  'bluez/gatt-types.vala',
  'bluez/bluez-adapter.vala',
  'bt/bt-class.vala',
  'bt/rfcomm-binding.vala',
  'bt/bt-session.vala',
  'bt/rfcomm.c',
  'ui/main-window.vala',
  'ui/preferences-dialog.vala',
  'util/log.vala',
  'util/async-waiter.vala',
)

sources += configure_file(
  input: 'config.vala.in',
  output: 'config.vala',
  configuration: app_conf,
)

# The tray icon is optional: distributions without AppIndicator (or builds
# which do not want a tray) keep the old close-to-quit behaviour.
appindicator_opt = get_option('appindicator')
appindicator_found = false
if appindicator_opt.allowed()
  appindicator_dep = dependency('ayatana-appindicator3-0.1', required: false)
  if not appindicator_dep.found()
    appindicator_dep = dependency('appindicator3-0.1', required: false)
  endif
  if appindicator_opt.enabled() and not appindicator_dep.found()
    error('appindicator=enabled but neither ayatana-appindicator3-0.1 nor appindicator3-0.1 was found')
  endif
  if appindicator_dep.found()
    sources += files('ui/tray-icon.vala')
    appindicator_found = true
  endif
endif

# These warnings originate in Vala's generated C (nullable string property
# setters, zero-argument closure casts) and in a libsoup vapi typo
# (const char* vs guint8[]), not in this project's sources.
vala_flags = ['--target-glib=2.66']
if appindicator_found
  vala_flags += [
    '--define=HAVE_APPINDICATOR',
    '--vapidir=' + meson.current_source_dir() / 'vapi',
  ]
endif

# See the comment above the target definitions: these silence warnings from
# Vala-generated C and from a libsoup vapi typo.
c_warning_flags = [
  '-Wno-discarded-qualifiers',
  '-Wno-pointer-sign',
  # libayatana-appindicator's simple constructor is deprecated but the
  # replacement library is not available everywhere.
  '-Wno-deprecated-declarations',
  '-Wno-cast-function-type',
  '-Wno-unused-parameter',
  '-Wno-unused-but-set-variable',
  '-Wno-unused-function',
  '-Wno-unused-variable',
  '-Wno-alloc-size',
  '-Wno-missing-field-initializers',
  '-Wno-unused-label',
]

deps = [
  dependency('gtk+-3.0', version: '>= 3.24'),
  dependency('gio-2.0'),
  dependency('gio-unix-2.0'),
  dependency('libsoup-3.0', version: '>= 3.0'),
  dependency('json-glib-1.0'),
]
if appindicator_found
  deps += appindicator_dep
endif

executable('scratch-link',
  sources,
  dependencies: deps,
  vala_args: vala_flags,
  c_args: c_warning_flags,
  install: true)

test_json_rpc = executable('test-json-rpc',
  ['tests/test-json-rpc.vala', 'protocol/json-rpc.vala', 'protocol/uri.vala',
   'settings.vala', 'util/log.vala'],
  dependencies: [dependency('gio-2.0'), dependency('json-glib-1.0')],
  vala_args: vala_flags,
  c_args: c_warning_flags)

test('json-rpc', test_json_rpc)

test_ble = executable('test-ble',
  [
    'tests/test-ble.vala',
    'ble/gatt-uuid.vala',
    'ble/gatt-policy.vala',
    'ble/byte-encoding.vala',
    'ble/scan-filter.vala',
    'bluez/bluez-types.vala',
    'bluez/gatt-types.vala',
    'bt/bt-class.vala',
    'protocol/json-rpc.vala',
    'util/log.vala',
  ],
  dependencies: [dependency('gio-2.0'), dependency('json-glib-1.0')],
  vala_args: vala_flags,
  c_args: c_warning_flags)

test('ble', test_ble)

test_rfcomm = executable('test-rfcomm',
  ['tests/test-rfcomm.c', 'bt/rfcomm.c'],
  dependencies: [dependency('gio-2.0')],
  include_directories: include_directories('.'),
  c_args: c_warning_flags)

test('rfcomm', test_rfcomm)
