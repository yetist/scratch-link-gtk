%global _description %{expand:
Scratch Link runs a small local WebSocket server that lets Scratch talk to
Bluetooth LE and Bluetooth Classic (RFCOMM) devices such as micro:bit,
LEGO BOOST, LEGO WeDo 2.0 and other GATT or serial peripherals. It talks to
BlueZ over D-Bus and speaks the same protocol as the official Scratch Link
applications.}

Name:           scratch-link-gtk
Version:        0.1.0
Release:        1%{?dist}
Summary:        Bluetooth bridge between Scratch and local peripherals
License:        GPL-3.0-or-later
URL:            https://github.com/yetist/scratch-link-gtk
Source0:        %{url}/releases/download/v%{version}/scratch-link-gtk-%{version}.tar.xz

BuildRequires:  gcc
BuildRequires:  meson >= 0.59
BuildRequires:  ninja-build
BuildRequires:  vala >= 0.48
BuildRequires:  pkgconfig(glib-2.0) >= 2.66
BuildRequires:  pkgconfig(gio-2.0)
BuildRequires:  pkgconfig(gio-unix-2.0)
BuildRequires:  pkgconfig(gtk+-3.0) >= 3.24
BuildRequires:  pkgconfig(libsoup-3.0) >= 3.0
BuildRequires:  pkgconfig(json-glib-1.0)
BuildRequires:  pkgconfig(ayatana-appindicator3-0.1)
BuildRequires:  systemd-rpm-macros
Requires:       bluez

%{!?_userunitdir:%global _userunitdir %{_prefix}/lib/systemd/user}

%description
%{_description}

%prep
%autosetup

%build
%meson -Dsystemd=true
%meson_build

%check
%meson_test

%install
%meson_install

%files
%license COPYING
%doc README.md
%{_bindir}/scratch-link
%{_datadir}/applications/org.scratchlink.Gtk.desktop
%{_datadir}/metainfo/org.scratchlink.Gtk.metainfo.xml
%{_datadir}/icons/hicolor/scalable/apps/org.scratchlink.Gtk.svg
%{_mandir}/man1/scratch-link.1*
%{_userunitdir}/scratch-link.service

%changelog
* Tue Nov 24 2026 Xiaotian Wu <yetist@gmail.com> - 0.1.0-1
- Initial package
