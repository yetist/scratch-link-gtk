# 打包与发布

本目录收集发行版打包文件、Flatpak 清单和发布说明。所有打包方式都只依赖
Meson 构建系统，安装内容由 `meson install` 决定，因此 RPM / deb / Arch /
Flatpak 的包内容保持一致。

| 文件 | 用途 |
| --- | --- |
| `flatpak/org.scratchlink.Gtk.yml` | Flatpak / Flathub 清单（本地构建用 `type: dir`） |
| `rpm/scratch-link-gtk.spec` | Fedora / RHEL / openSUSE 的 RPM spec |
| `arch/PKGBUILD` | Arch Linux / AUR |
| `../debian/` | Debian / Ubuntu 打包 |

## 版本号

版本号只有一个权威来源，发布前修改：

- `meson.build` 的 `project(..., version: ...)`

`src/config.vala.in` 由 Meson 生成，`scratch-link --version` 自动跟随。
另外需要同步的只有发布元数据和打包文件：

- `data/org.scratchlink.Gtk.metainfo.xml` 的 `<release version=...>`
- 打包文件中的 `Version:` / `pkgver=` / `debian/changelog`

## 发布检查清单

```sh
# 1. 干净构建与测试
meson setup build --buildtype=release --prefix=/usr
meson compile -C build
meson test -C build --print-errorlogs

# 2. 元数据校验
desktop-file-validate data/org.scratchlink.Gtk.desktop
appstreamcli validate --no-net data/org.scratchlink.Gtk.metainfo.xml

# 3. 安装树检查（Man page、systemd 单元、图标都应在）
DESTDIR="$PWD/install-root" meson install -C build
find install-root -type f | sort

# 4. 源码包
meson dist -C build --no-tests

# 5. 打标签并推送，GitHub Actions 会生成并附加
#    - scratch-link-gtk-<version>.tar.xz
#    - scratch-link-gtk.flatpak
#    - RPM / SRPM
git tag -s v0.1.0 -m "scratch-link-gtk 0.1.0"
git push origin v0.1.0
```

发布工作流见 `.github/workflows/release.yml`，CI 见
`.github/workflows/ci.yml`。

## Flatpak

权限说明：

- `--share=network`：Scratch 在宿主机浏览器里连接 `127.0.0.1:20111`，沙箱必须共享网络；
- `--allow=bluetooth`：允许 `AF_BLUETOOTH` socket，Bluetooth Classic / RFCOMM 需要；
- `--system-talk-name=org.bluez`：BlueZ 在系统总线，BLE 扫描和 GATT 都走它。

本地构建与运行：

```sh
flatpak-builder --user --install --force-clean \
    build-flatpak packaging/flatpak/org.scratchlink.Gtk.yml
flatpak run org.scratchlink.Gtk
```

只生成单文件 bundle：

```sh
flatpak-builder --force-clean --repo=repo build-flatpak \
    packaging/flatpak/org.scratchlink.Gtk.yml
flatpak build-bundle repo scratch-link-gtk.flatpak org.scratchlink.Gtk
```

Flatpak 中禁用托盘和 systemd 单元（`-Dappindicator=disabled -Dsystemd=false`）：
AppIndicator 不在运行时内，systemd 用户单元也无法从沙箱安装。关闭窗口即退出。

### 提交 Flathub

当前清单的源码是 `type: dir`，方便本地和 CI 从工作区构建。提交 Flathub 时把
`sources` 换成发布页上的源码包，并填入真实 sha256：

```yaml
    sources:
      - type: archive
        url: https://github.com/yetist/scratch-link-gtk/releases/download/v0.1.0/scratch-link-gtk-0.1.0.tar.xz
        sha256: <发布包的 sha256>
```

Flathub 还要求 AppStream 元数据包含截图。`data/org.scratchlink.Gtk.metainfo.xml`
已经引用 `data/screenshots/main-window.png` 的 GitHub raw 地址，发布前确认仓库公开且
图片可访问；替换截图时保持 16:9 或 4:3 比例。应用 ID `org.scratchlink.Gtk` 一旦在
Flathub 发布就不应再修改。

## Debian / Ubuntu

```sh
sudo apt install build-essential debhelper meson ninja-build valac \
    libglib2.0-dev libgtk-3-dev libsoup-3.0-dev libjson-glib-dev \
    libayatana-appindicator3-dev
dpkg-buildpackage -b -uc -us
sudo apt install ../scratch-link_0.1.0-1_amd64.deb
```

`debian/rules` 使用 debhelper 的 Meson 支持；`debian/tests/smoke` 提供
autopkgtest 级别的冒烟测试（`scratch-link --version`、`--help`）。托盘依赖是
`Recommends`，构建时没有 AppIndicator 也不会失败。

## RPM

用发布包构建（推荐，spec 中的 `Source0` 指向 GitHub Release）：

```sh
rpmdev-setuptree
spectool -g -R packaging/rpm/scratch-link-gtk.spec
rpmbuild -ba packaging/rpm/scratch-link-gtk.spec
```

或从本地源码包构建：

```sh
cp build/meson-dist/scratch-link-gtk-0.1.0.tar.xz ~/rpmbuild/SOURCES/
cp packaging/rpm/scratch-link-gtk.spec ~/rpmbuild/SPECS/
rpmbuild -ba ~/rpmbuild/SPECS/scratch-link-gtk.spec
```

## Arch Linux

```sh
cd packaging/arch
makepkg -si
```

`PKGBUILD` 直接使用 `v$pkgver` 标签，`sha256sums=('SKIP')` 只适用于 git 源；
如果改用 tarball 源，请填写发布包的校验和。AUR 提交时把 `Maintainer` 改成
实际维护者。

## systemd 用户服务

默认安装 `$(prefix)/lib/systemd/user/scratch-link.service`，不自动启用：

```sh
systemctl --user daemon-reload
systemctl --user enable --now scratch-link.service
```

不需要该单元时（例如 Flatpak、容器镜像）配置 `-Dsystemd=false`。
