# MacView

[English](README.md)

MacView 是一款受 [NeeView](https://github.com/neelabo/NeeView) 启发的 macOS 原生图片浏览器，使用 Swift 6 与 AppKit 开发，面向图片集浏览、漫画阅读和图视频混合内容查看。

## 主要功能

- 浏览文件夹及未加密的 ZIP/CBZ、TAR、TAR.GZ 和 GZIP 压缩包，支持嵌套压缩包。
- 支持单页、双页、纵向连续、横向连续和瀑布流浏览方式。可自由缩放、查看动图及播放 AVFoundation 支持的视频。
- 支持本地文件及系统挂载的 SMB、NFS 网络卷，通过按需解码、预取和有容量限制的缓存提升浏览响应速度。
- 灵活布局停靠面板，在列表、详情表格、网格和瀑布流之间切换；支持多窗口和标签页，恢复阅读位置。
- 使用书签、浏览历史、播放列表、搜索、评分和标签管理内容。可在浏览时复制、移动、重命名、分类和删除文件。
- 定制快捷键、手势、菜单、工具栏、主题、布局和显示配置，支持导出与导入 MacView 用户数据。
- 通过 JavaScript 脚本、自定义命令和插件扩展浏览器，包括数据源、面板和图像滤镜。

图片解码使用 ImageIO，视频播放使用 AVFoundation。压缩包内的文件只读；暂不支持 RAR、7z 及加密压缩包。

## 系统要求

- macOS 27 或更高版本。
- 如需从源码构建，需要包含 macOS 27 SDK 的 Xcode，并通过 [Homebrew](https://brew.sh/) 安装 XcodeGen。

## 下载安装

1. 从 [GitHub Releases](https://github.com/ump45nose/MacView/releases) 下载 ad-hoc 签名的 ZIP 包及配套 SHA-256 校验文件。验证下载时，可以在下载目录下用 `shasum -a 256 -c` 加校验文件名执行检查。
2. 解压后将 `MacView.app` 放入 `/Applications`。
3. 公开发布包使用 ad-hoc 签名，未经公证。如果首次启动被 macOS 拦截，可尝试在 Finder 中通过右键菜单打开，也可以移除下载隔离属性：

   ```sh
   xattr -dr com.apple.quarantine /Applications/MacView.app
   ```

   然后正常打开 MacView。

## 从源码构建

克隆仓库并构建 App：

```sh
git clone https://github.com/ump45nose/MacView.git
cd MacView
brew install xcodegen
make build
```

Debug 版 App 生成在 `build/DerivedData/Build/Products/Debug/MacView.app`。可使用 `make run` 启动。

运行测试：

```sh
make test
```

### 本机签名与安装

开发构建和 Debug 自检仍使用 ad-hoc 签名，重新构建后系统可能再次询问网络卷访问权限。

若要使用稳定的本机安装签名身份，先创建一次本机自签证书，再当场构建并安装本机包：

```sh
scripts/setup-signing.sh
scripts/install.sh local --build
```

第一条命令可能需要钥匙串授权。本机安装渠道每次构建都复用同一个 `MacView Local Development` 签名身份，旨在保留网络卷访问权限，与 ad-hoc 公开分发渠道分开。也可使用 `scripts/package.sh --local` 单独打包本机版，公开包使用 `scripts/package.sh --adhoc`。

## 脚本与插件

MacView 支持通过命令系统使用 JavaScript 脚本和外部命令，也支持 JavaScript 插件、HTML/JavaScript 面板及外部进程插件。

- [Examples/Plugins](Examples/Plugins/) 提供数据源、面板、命令和滤镜插件示例。
- [PluginSupport/python](PluginSupport/python/) 提供外部进程插件的 Python 支持模块。

可在设置中的「扩展」一节管理脚本和插件。

## 参与开发

请勿将个人路径、网络地址或凭据提交到仓库。可选的本机网络测试配置见 [Fixtures/environment.example.json](Fixtures/environment.example.json)。

提交改动前运行通用隐私检查：

```sh
scripts/privacy-check --staged --generic-only
```

CI 会检查通用隐私规则。新增或改动截图的文字识别只在本机推送前钩子里运行，因为 GitHub 的 macOS runner 上无法使用 Vision 文字识别。如果你在 `~/.config/macview/privacy-patterns.txt` 维护了非空的私有精确词表，可以安装仓库的推送前钩子：

```sh
scripts/install-hooks.sh
```

钩子检查历史来源及待推送提交，并要求存在私有词表。没有词表的贡献者可显式使用 `--generic-only` 进行本地检查。

## 许可证

MacView 使用 [MIT 许可证](LICENSE)。随 App 分发的第三方软件许可见 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES)。
