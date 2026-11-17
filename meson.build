project('scratch-link-gtk', 'vala', 'c',
  version: '0.1.0',
  license: 'GPL-3.0-or-later',
  meson_version: '>= 0.59',
  default_options: ['warning_level=2'])

subdir('src')
subdir('data')

summary({
  'Version': meson.project_version(),
  'Prefix': get_option('prefix'),
}, section: 'Scratch Link for Linux')
