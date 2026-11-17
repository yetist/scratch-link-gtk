# Scratch Link for Linux (GTK 3)

在 Linux 桌面上把 Scratch 3 与蓝牙外设连接起来的本地服务，使用 Vala + GTK 3 编写。
协议与官方 Scratch Link 2.x 兼容，通过 `ws://127.0.0.1:20111/scratch/ble` 与
`ws://127.0.0.1:20111/scratch/bt` 提供 BLE 与 Bluetooth Classic（RFCOMM）会话，
外设访问通过 BlueZ 的 D-Bus API 与 libbluetooth，无需 `setcap`、无需修改 NSS 数据库或 `/etc/hosts`。

## 依赖

- GTK 3.24+
- GLib / GIO 2.66+
- libsoup 3
- json-glib 1.0
- Vala 0.48+ 与 Meson 0.59+（仅构建时需要）
- BlueZ（`bluetoothd`）在系统总线上运行
- libbluetooth（`libbluetooth-dev` / `bluez-libs-devel`），用于 Bluetooth Classic / RFCOMM
- 可选：libayatana-appindicator3（托盘图标）

Debian / Ubuntu：

```sh
sudo apt install build-essential meson ninja-build valac \
    libgtk-3-dev libglib2.0-dev libsoup-3.0-dev libjson-glib-dev \
    libbluetooth-dev
# 可选：托盘图标
sudo apt install libayatana-appindicator3-dev
```

Fedora：

```sh
sudo dnf install gcc meson ninja-build vala gtk3-devel glib2-devel \
    libsoup3-devel json-glib-devel bluez-libs-devel
# 可选：托盘图标
sudo dnf install libayatana-appindicator-gtk3-devel
```

## 构建

```sh
meson setup build --prefix=/usr
ninja -C build
meson test -C build
```

## 安装

```sh
sudo meson install -C build
```

安装内容：

| 路径 | 内容 |
| --- | --- |
| `$(prefix)/bin/scratch-link` | 可执行文件 |
| `$(prefix)/lib/systemd/user/scratch-link.service` | systemd 用户服务（未自动启用） |
| `$(datadir)/applications/org.scratchlink.Gtk.desktop` | 桌面入口 |
| `$(datadir)/icons/hicolor/scalable/apps/org.scratchlink.Gtk.svg` | 图标 |
| `$(datadir)/metainfo/org.scratchlink.Gtk.metainfo.xml` | AppStream 元数据 |

## 运行

```sh
./build/src/scratch-link            # 图形界面
./build/src/scratch-link --headless # 无界面（适合 systemd / 容器）
```

常用选项：

```text
--port=PORT              监听端口（默认 20111）
--listen-address=ADDR    绑定地址（默认 127.0.0.1）
--adapter=NAME           指定适配器，例如 hci0
--min-rssi=DBM           低于该 RSSI 的设备不上报（默认 -90）
--headless               不启动图形界面
--verbose, -v            输出调试日志
--version                打印版本
```

没有可用的显示服务器时，程序会自动转入无头模式。

### 托盘图标

检测到 Ayatana AppIndicator（或旧版 AppIndicator 3）时，图形界面会创建一个托盘图标。
构建时可用 `-Dappindicator=disabled` 关闭，或用 `-Dappindicator=enabled` 强制要求该依赖。
托盘菜单包含“显示 Scratch Link”“复制服务地址”“打开状态页”和“退出”；有可用托盘时，
关闭主窗口只会隐藏它，服务继续运行。

托盘需要桌面提供 StatusNotifier 宿主。KDE、XFCE 等通常自带；GNOME 需要安装
AppIndicator/KStatusNotifierItem 扩展。没有宿主时程序不会创建托盘，关闭窗口仍然直接退出，
不会留下无法找回的后台进程。

### 配置与首选项

命令行参数的优先级最高，其次是 `~/.config/scratch-link/settings.ini`，最后是内置默认值。
图形界面的“首选项”可以修改：

- 监听端口（重启后生效）
- 蓝牙适配器（自动选择或指定 `hci0` 等，重启后生效）
- 最低 RSSI（立即生效，低于该值的设备不会出现在 Scratch 列表）
- 详细日志（立即生效）

配置文件由“首选项 → 应用”写入，格式为简单的 INI：

```ini
[general]
port=20111
listen-address=127.0.0.1
adapter=
min-rssi=-90
verbose=false
```

命令行覆盖值会同时用于本次运行；如果随后在首选项中点击“应用”，当前生效值会被写入文件。

默认只监听 `127.0.0.1`。如果把 `--listen-address` 设为 `0.0.0.0` 或 `::`，任何能访问该端口的
程序都可以控制已连接的蓝牙设备；请只在可信网络中使用，程序会在日志中给出警告。

### 作为 systemd 用户服务

安装包同时提供一个不自动启用的用户服务。希望登录后在后台运行时：

```sh
systemctl --user daemon-reload
systemctl --user enable --now scratch-link.service
journalctl --user -u scratch-link.service -f
```

该服务使用 `--headless`，不会打开窗口，并默认监听 `127.0.0.1:20111`。它与图形界面共用
同一个端口，不要同时运行；需要改端口或指定适配器时，可用
`systemctl --user edit scratch-link.service` 覆盖 `ExecStart`。

主窗口显示服务地址、蓝牙适配器状态、最近发现的设备（名称、RSSI、是否已连接）以及可折叠、
可清空的日志。顶部圆点会随适配器状态变为绿色、黄色或红色；菜单里可以打开首选项、复制 BLE
地址或打开浏览器状态页。`--adapter` 可以按适配器名称选择，例如 `--adapter hci0`；名称同时
匹配 BlueZ 的 `Name`/`Alias` 属性，找不到时不会悄悄改用其他适配器。

启动后可以在浏览器打开 <http://127.0.0.1:20111/> 查看服务状态。

## 与 Scratch 一起使用

1. 启动 `scratch-link`；
2. 打开 <https://scratch.mit.edu/projects/editor/> 或 Scratch 桌面版；
3. 添加使用蓝牙 LE 的扩展（micro:bit、LEGO BOOST、WeDo 2.0 等）；
4. Scratch 会自动连接 `ws://127.0.0.1:20111/scratch/ble`，设备列表出现在扩展面板中。

### micro:bit 无法连接

Scratch 的 micro:bit 扩展要求 micro:bit 运行 **Scratch 专用固件**。该固件暴露服务
`0000f005-0000-1000-8000-00805f9b34fb`，并使用特征 `5261da01-…`（通知）与
`5261da02-…`（写入）。普通 MakeCode 程序或出厂固件通常只有 Device Information、
`e95d…`/`e97d…` 等标准服务，没有 `0xf005`，因此 BLE 能连上，但 Scratch 随后读取/订阅时会失败。

处理步骤：

1. 从 Scratch micro:bit 扩展的安装提示，或
   <https://downloads.scratch.mit.edu/microbit/scratch-microbit.hex.zip>
   下载 Scratch micro:bit hex；
2. 用 USB 连接 micro:bit，把 hex 拖到 `MICROBIT` U 盘，等待 LED 滚动显示新的五位名称；
3. 在系统蓝牙设置中删除该 micro:bit 的旧配对记录；
4. 重新上电，确认 `BBC micro:bit [...]` 出现在可发现列表，再在 Scratch 中连接。

使用 `scratch-link -v` 可以在连接时看到实际 GATT 服务列表；如果日志出现
`micro:bit is not running the Scratch firmware (missing service 0xf005)`，说明设备固件不对，
不是 scratch-link 的连接问题。

## 权限说明

程序通过系统 D-Bus 访问 `org.bluez`。大多数发行版允许本地用户扫描与连接设备；
如果遇到 `org.bluez.Error.NotAuthorized` 或 `org.bluez.Error.NotPermitted`：

- 确认 `bluetooth.service` 正在运行：`systemctl status bluetooth`；
- 确认适配器未被 rfkill 关闭：`rfkill list bluetooth`；
- 某些发行版需要把用户加入 `bluetooth` 组，或安装 polkit 规则。

## 许可证

GPL-3.0-or-later，详见 [COPYING](COPYING) 与各源文件头部的 SPDX 标记。
协议实现依据官方 `Documentation/NetworkProtocol.md`、`Documentation/BluetoothLE.md`
与 Web Bluetooth 规范独立编写。
