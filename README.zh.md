# HandyKopie – 适用于 Windows 的安卓手机备份工具（MTP + adb）

**语言 / Language：** [English](README.md) · [Deutsch](README.de.md) ·
[Français](README.fr.md) · [Русский](README.ru.md) · [中文](README.zh.md)

HandyKopie 是一款免费的便携式 Windows 工具，可将安卓手机（通过 USB/MTP
连接，例如小米/红米）中的文件复制到电脑——支持文件夹选择、按文件类型
搜索、单文件下载、增量备份、快速的 adb「涡轮」模式、手机清理（缓存/
更新残留）以及干净的应用卸载。无需安装、无需云、无广告——所有数据都
保留在您的电脑上。

> 可直接运行的发布版：[`release/HandyKopie_UI.zip`](release/HandyKopie_UI.zip)
> （内含 `adb`；SHA256 见 [`release/SHA256SUMS.txt`](release/SHA256SUMS.txt)）

## 功能特性

- **文件夹选择树**（左侧），带复选框，支持部分选择（取消勾选的子文件夹
  会被排除）。
- **内部存储 / SD 卡**切换。
- **右侧浏览器**：点击左侧文件夹即可立即查看其中的文件；通过双击和
  「向上」按钮导航。
- **文件类型过滤 + 全盘搜索**：勾选例如*图片*、*视频*、*音频*、*APK*、
  *文档*（或自定义扩展名），然后点击「搜索手机」——程序会列出所有包含
  匹配文件的文件夹；打开文件夹后可双击**下载单个文件**，或复制整个
  文件夹。
- **缩略图视图**（带预览的大图标，类似 Windows 资源管理器）。
- **默认隐藏系统文件夹**（Android、MIUI、缓存等）——可用复选框显示。
- **涡轮模式（adb pull）**——大数据量时比 MTP 快很多倍（仅内部存储；
  其他情况自动回退到 MTP）。
- **增量备份**——重复运行时只传输新增/更改的文件；重复文件（同名且同
  大小）无需询问直接跳过。
- **重复文件检测**，带明确的「是/否」询问（覆盖或跳过）。
- **目标位置中的手机文件夹**：所有内容保存在
  `<目标路径>\<手机名称>\…` 下，多台设备互不混淆。
- **容错设计**：单个坏文件绝不会中断整个任务——错误会立即写入临时日志
  （`%TEMP%\HandyKopie_Fehler_*.txt`，结束后自动打开），并继续复制下一个
  文件。
- **清理功能**，缓解手机变慢：缩略图、应用缓存（当 Android 对 MTP 隐藏
  缓存时通过 adb `pm trim-caches` 清理）、临时文件夹以及过期的安卓更新
  残留——每项均显示大小**和文件数量**。
- **应用管理**：列出已安装的第三方应用并*干净地*卸载（应用本体 +
  残留文件夹 `Android/data` / `Android/obb`）。
- **按拍摄日期整理照片**：JPG 还会按 EXIF 拍摄日期额外整理到 `Fotos_sortiert\YYYY-MM`。
- **实时进度**（百分比、文件计数、当前文件）以及有效的「取消」按钮。

## 系统要求

- Windows 10/11，PowerShell 5.1（Windows 自带）。
- USB 数据线；手机已解锁；USB 模式为「文件传输 / MTP」。
- 建议开启 **USB 调试**（设置 → 关于手机 → 连续点击版本号 7 次 →
  开发者选项 → USB 调试）并信任本电脑——涡轮模式、深度清理和应用管理
  需要此设置。
- `adb` 已随附（`platform-tools/`）；如被删除，可运行
  `tools/get_platform_tools.ps1` 从 Google 官方下载。

## 快速开始（3 步）

1. 下载 [`release/HandyKopie_UI.zip`](release/HandyKopie_UI.zip) 并解压到
   **同一个**文件夹（保留其中的 `platform-tools`）。
2. 连接手机（已解锁、MTP 模式），双击 `Start_HandyKopie_UI.bat`。
3. 在左侧勾选文件夹，选择目标路径，点击**开始复制**。
   （首次使用 adb 时，请在手机上确认「信任此计算机」。）

## 文档

- 完整手册：[`docs/`](docs/) – `MANUAL.zh.txt` 等
- 源代码：[`app/HandyKopieUI.ps1`](app/HandyKopieUI.ps1)（单文件 WinForms
  PowerShell 应用），启动器：
  [`app/Start_HandyKopie_UI.bat`](app/Start_HandyKopie_UI.bat)

## 安全与隐私

- 您的文件绝不离开电脑：USB 直接复制，无云、无遥测。
- 清理与卸载不会触碰系统应用和个人文件；所有破坏性操作都会先询问并
  记录日志。
- 程序绝不会静默中断：每个错误都带时间戳记录。

## 许可证与第三方组件

- 自有代码：**MIT**（见 [`LICENSE`](LICENSE)）。
- 随附的 Android SDK Platform-Tools（adb）：**Apache-2.0**，
  Copyright (C) Google LLC，未修改分发（见 [`NOTICE`](NOTICE)）。

## 校验完整性

```powershell
Get-FileHash release\HandyKopie_UI.zip -Algorithm SHA256
# 与 release\SHA256SUMS.txt 对比
```

## 更新日志

见 [`CHANGELOG.md`](CHANGELOG.md)。
