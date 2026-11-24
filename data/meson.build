install_data(
  'org.scratchlink.Gtk.desktop',
  install_dir: get_option('datadir') / 'applications',
)

install_data(
  'org.scratchlink.Gtk.metainfo.xml',
  install_dir: get_option('datadir') / 'metainfo',
)

install_data(
  'icons/org.scratchlink.Gtk.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps',
)

install_man('scratch-link.1')

service_conf = configuration_data()
service_conf.set('BINDIR', get_option('prefix') / get_option('bindir'))
if get_option('systemd')
  configure_file(
    input: 'scratch-link.service.in',
    output: 'scratch-link.service',
    configuration: service_conf,
    install: true,
    install_dir: get_option('prefix') / 'lib/systemd/user',
  )
endif
