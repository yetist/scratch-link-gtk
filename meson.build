project('scratch-link-gtk', 'vala', 'c',
  version: '0.1.0',
  license: 'GPL-3.0-or-later',
  meson_version: '>= 0.59',
  default_options: ['warning_level=2'])

app_id = 'org.scratchlink.Gtk'
protocol_version = '1.2'

app_conf = configuration_data()
app_conf.set('VERSION', meson.project_version())
app_conf.set('APP_ID', app_id)
app_conf.set('PROTOCOL_VERSION', protocol_version)

subdir('src')
subdir('data')

summary({
  'Version': meson.project_version(),
  'Prefix': get_option('prefix'),
}, section: 'Scratch Link for Linux')
