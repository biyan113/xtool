# 在 Linux 上打包 Flutter 的 macOS / Windows 应用

`build-macos.sh` 和 `build-windows.sh` 在 Linux（例如 CI 打包机）上把一个 Flutter 项目打成可以直接运行的
macOS arm64 `.app` 和 Windows x64 程序，不需要 Mac 或 Windows 机器。macOS 部分用的是本仓库 xtool 装好的
Darwin SDK 和 `ld64.lld`。

两个脚本打出的都是 **调试（JIT）版**：功能完整，但启动比正式版慢、内存占用更大。原因见文末
[为什么是调试版](#为什么是调试版)。

## 快速开始

```bash
# macOS：在 Flutter 项目根目录
bash /path/to/xtool/flutter/build-macos.sh \
  --app-name MyApp \
  --bundle-id com.example.myapp \
  --nib packaging/macos/MainMenu.nib \
  --icon packaging/macos/AppIcon.icns
# -> dist/MyApp-macos-arm64.zip（解压得到 MyApp.app）

# Windows
bash /path/to/xtool/flutter/build-windows.sh --app-name MyApp
# -> dist/MyApp-windows-x64.zip（解压后运行 MyApp\MyApp.exe）
```

`--help` 列出全部参数。

## 环境要求

| | macOS 包 | Windows 包 |
| --- | --- | --- |
| Flutter | `flutter` 在 PATH 上（Linux 版即可） | 同左 |
| 编译器 | xtool 的 Swift 工具链（`swiftc`）、`clang`（或用 `CLANG` 指定） | `clang-cl`、`llvm-rc`（LLVM 18 及以上） |
| 链接器 | xtool 的 `ld64.lld` | `lld-link`；没有时自动借用 xtool 的 `ld64.lld` |
| SDK | `xtool setup` 安装的 `darwin.xtoolsdk`（默认 `/opt/xtool/darwin.xtoolsdk`，可用 `XTOOL_SDK_BUNDLE` 改） | 首次运行由 [xwin](https://github.com/Jake-Shadle/xwin) 自动下载 MSVC 运行库和 Windows SDK（等于接受微软的许可协议） |
| 其他 | `python3`、`curl`、`unzip`、`zip` | 同左 |

下载的东西都放在缓存目录里（`--cache`，默认 `$XTOOL_FLUTTER_CACHE` 或 `~/.cache/xtool-flutter`），按 Flutter
引擎版本分开存放，只下载一次：

```
<cache>/flutter-engine/<引擎版本>/macos/    FlutterMacOS.framework.zip、artifacts.zip
<cache>/flutter-engine/<引擎版本>/windows/  flutter-debug.zip、cpp-client-wrapper.zip、artifacts.zip
<cache>/xwin/                              xwin 和解出的 sysroot（约 1 GB）
<cache>/rcodesign-0.29.0                   ad-hoc 签名工具
```

缓存目录必须对运行脚本的用户可写（CI 里通常是 runner 用户）。

## 对项目的要求

### macOS

- **`MainMenu.nib`（必需）**：Linux 上没有 `ibtool`，没法编译 `MainMenu.xib`。在任意一台 Mac 上 `flutter build macos`
  一次，把 `build/macos/Build/Products/Release/<App>.app/Contents/Resources/Base.lproj/MainMenu.nib` 复制进仓库即可；
  只有改了 `MainMenu.xib` 才需要重新复制。
- **模块名要和 nib 一致**：nib 按 Swift 模块名记录类名（例如 `_TtC6MyApp11AppDelegate`）。Xcode 用的模块名是
  `PRODUCT_NAME`，默认等于 `--app-name`；不一致时用 `--swift-module` 指定。脚本会检查，不一致直接报错——否则打出来
  的程序能启动，但没有窗口，也不加载 Flutter。
- **`AppIcon.icns`（可选）**：同样从一次 Mac 构建的 `Contents/Resources/` 里复制。
- **Info.plist 额外条目**：`--plist-entries` 指向一个只含 `<key>…</key><string>…</string>` 的文件，例如：

  ```xml
  <key>NSLocalNetworkUsageDescription</key><string>需要访问局域网来发现其他设备。</string>
  ```

  版本号自动取 `pubspec.yaml` 的 `version`。
- **原生代码**：`macos/Runner/*.swift` 和 `GeneratedPluginRegistrant.swift` 会被编译，可以写自己的平台通道；
  链接额外的系统框架用 `--framework`（可重复）。
- **插件**：带 Swift/Objective-C 代码的插件（`GeneratedPluginRegistrant.swift` 里有 `import` 的）**不支持**，脚本会列出
  并停止。纯 Dart 和 FFI 的插件没问题；`package:objective_c`（`path_provider` 等会用到）会自动编成
  `objective_c.framework`。
- **签名**：ad-hoc 签名，没有 entitlements（不开沙盒）。没有公证，用户第一次打开要在「隐私与安全性」里允许，或者
  `xattr -dr com.apple.quarantine MyApp.app`。

### Windows

- 用 `flutter create --platforms=windows .` 生成的 `windows/` 工程即可。`windows/runner/*.cpp` 全部参与编译，
  可以加自己的 C++ 文件；用到的系统库用 `--lib`（例如 `--lib windowscodecs`）。
- 资源（`Runner.rc`：图标、版本信息）和 `runner.exe.manifest` 会编进 exe，版本号取自 `pubspec.yaml`。
- **插件**：带 C++ 代码的插件（`generated_plugins.cmake` 的 `FLUTTER_PLUGIN_LIST`）**不支持**，脚本会停止；
  `FLUTTER_FFI_PLUGIN_LIST` 里的 FFI 插件不会被打包，脚本会提示（只在其他平台用到的可以忽略，比如
  `path_provider_android` 带进来的 `jni`）。
- C 运行库静态链接（`/MT`），目标电脑不需要安装 VC++ 运行库。

## 在 Gitea / GitHub Actions 中使用

固定一个 xtool 版本（提交 SHA 或 tag），在打包步骤里取出脚本：

```yaml
jobs:
  macos:
    runs-on: 打包          # 装好 Flutter、xtool 和 Darwin SDK 的 runner
    env:
      XTOOL_REF: <xtool 的提交 SHA>
      XTOOL_FLUTTER_CACHE: /data/gitea-cache
    steps:
      - uses: actions/checkout@v4
      - name: build
        run: |
          set -euo pipefail
          tools="$XTOOL_FLUTTER_CACHE/xtool-src/$XTOOL_REF"
          if [ ! -d "$tools" ]; then
            git clone --filter=blob:none https://github.com/biyan113/xtool "$tools.tmp"
            git -C "$tools.tmp" checkout --quiet "$XTOOL_REF"
            mv "$tools.tmp" "$tools"
          fi
          bash "$tools/flutter/build-macos.sh" --app-name MyApp --bundle-id com.example.myapp \
            --nib packaging/macos/MainMenu.nib --icon packaging/macos/AppIcon.icns
      - run: ls -lh dist/
```

Windows 同理，把最后的命令换成 `build-windows.sh`。

## 为什么是调试版

Flutter 的正式版把 Dart 代码预编译成机器码（AOT），编译器 `gen_snapshot` 只能在目标系统上运行：Flutter 不提供
在 Linux 上生成 macOS 或 Windows 机器码的版本。

试过借用 Android 的 Linux 版 `gen_snapshot`（同为 arm64）：生成的快照标着 `arm64 android compressed-pointers`，而
macOS 引擎只接受 `arm64 macos no-compressed-pointers`，引擎直接拒绝加载，修改符号名也没用。

调试版不需要这一步：Dart 代码以 `kernel_blob.bin`（与平台无关的中间格式）放进包里，由调试版引擎在目标电脑上即时
编译。所需的引擎文件都能从 Flutter 的下载站直接取到。要发正式版，仍需要在 macOS / Windows 上构建。

## 打包过程与踩过的坑

### macOS

1. 下载与本机 Flutter **同一引擎版本** 的 `darwin-x64/FlutterMacOS.framework.zip`（调试版引擎，zip 里还套着一个
   zip）和 `darwin-x64/artifacts.zip`。版本不一致时引擎报
   `Invalid kernel binary format version (expected …, found …)`。
2. `flutter build bundle --debug` 生成 `kernel_blob.bin` 等资源；它带的 `vm_snapshot_data` / `isolate_snapshot_data`
   是 Linux 的，换成 artifacts.zip 里 macOS 的 `vm_isolate_snapshot.bin` / `isolate_snapshot.bin`。
3. `App.framework` 在调试版里只是装资源的壳：编一个空的动态库，`flutter_assets` 放在它的 `Resources` 下。
4. `package:objective_c` 原本由它的 build hook 编译。照它的做法递归编译 `src/` 下 **所有** `.c` / `.m`——只编第一层会漏掉
   `src/include/dart_api_dl.c`，运行时报 `symbol not found '_Dart_PostInteger_DL'`。再写 `NativeAssetsManifest.json`
   指向这个框架。
5. 用 Swift 编译 `macos/Runner`。Swift 的 clang importer 固定使用 `<resource-dir>/clang`，而 Xcode 工具链里的这个目录没有
   `stdbool.h` 等头文件，所以另建一个 resource 目录：Swift 模块用工具链的，`clang` 指向 swiftc 自带的 clang。
6. Linux 上的 `swift-autolink-extract` 读不了 Mach-O，Swift 运行库要在链接时逐个写明；直接用 `ld64.lld` 链接。
   clang 驱动链接时经 `lib/apple-ld64.py` 把 Darwin 的链接参数转给 `ld64.lld`。
7. 组装 `.app`（Info.plist、nib、图标、框架），用 [rcodesign](https://github.com/indygreg/apple-platform-rs) 做 ad-hoc 签名。
   不能带沙盒 entitlements：沙盒 + ad-hoc 签名的程序会被 macOS 直接结束。
8. 排查：在 Mac 上直接运行 `MyApp.app/Contents/MacOS/MyApp`，引擎日志会打到终端。没有任何输出、进程里也没有
   Flutter 线程，多半是 nib 的类名和模块名不一致（见上）。

### Windows

1. 下载 `windows-x64-debug/windows-x64-flutter.zip`（`flutter_windows.dll` 和导入库）、`windows-x64/flutter-cpp-client-wrapper.zip`、
   `windows-x64/artifacts.zip`。artifacts 里的 `vm_isolate_snapshot.bin` 本来就是 0 字节，正常。
2. xwin 解出 MSVC CRT 和 Windows SDK；头文件要包含 `crt/include` 和 SDK 的 `ucrt`、`um`、`shared`、`winrt`
   （`wrl/client.h` 在 `winrt`）。
3. `clang-cl` 编译 runner 和 C++ 封装层（与 `windows/flutter/CMakeLists.txt` 相同的五个文件）。
4. `llvm-rc` 编译 `Runner.rc`。两个坑：它把以 `/` 开头的参数当成选项，Linux 的绝对路径会被误读，输入文件一律给
   相对路径；`Runner.rc` 里的 `resources\\app_icon.ico` 要换成 `/`。manifest 用一条 `1 24 "…"` 资源编进去，
   这样 `lld-link` 不需要 `mt.exe`。
5. `lld-link` 链接。没有 `lld-link` 时，给 xtool 的 `ld64.lld` 建个叫 `lld-link` 的软链接即可：lld 按程序名决定链接
   哪种格式。
6. 打包 `MyApp.exe`、`flutter_windows.dll`、`data/icudtl.dat`、`data/flutter_assets/`。

## 已知限制

- 只有调试（JIT）版；macOS 只出 arm64，Windows 只出 x64。
- 不支持带原生代码的插件（见上）。
- macOS 包没有公证，也不开沙盒。
- Windows 包没有安装程序，解压即用。
