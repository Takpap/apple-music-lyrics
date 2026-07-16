# Apple Music Lyrics

[English](README.md) | [简体中文](README.zh-CN.md)

一款非官方的 macOS 菜单栏应用，用于显示 Music.app 当前歌曲的同步歌词。
应用只读取 Apple Music 已有的本地缓存，不会请求第三方歌词服务。

> [!IMPORTANT]
> 本项目依赖 Music.app 的私有缓存格式，macOS 更新后可能失效。如果不替换
> 数据来源，它不适合直接提交到 Mac App Store。

## 功能

- 原生 AppKit 菜单栏应用，不显示 Dock 图标
- 使用 Apple Music TTML 实现词级卡拉 OK 高亮
- 在播放位置采样之间，以 60 fps 平滑更新状态栏歌词
- 根据 MacBook 和刘海屏自动调整状态栏宽度
- 长歌词在状态项内部滚动，不会持续挤占其他菜单栏图标
- 始终置顶的浮动歌词面板，支持歌词换行动画
- 在状态项菜单中预览当前歌词附近的内容
- 切换歌曲后自动重新扫描歌词缓存
- 无第三方依赖、无数据分析、不会提取账户令牌，也不会主动请求歌词

Apple Music 提供带时间信息的 `<span>` 元素，一个 span 可能包含一个或多个
字符。当 span 包含多个字符时，应用会在其时间范围内插值显示高亮进度；Apple
不一定为每个字符单独提供时间戳。

## 工作原理

```text
Music.app --AppleScript--> 歌曲信息和播放位置
    |
    +--本地 CFNetwork 缓存--> Apple Catalog JSON + 词级 TTML
                                      |
                                      v
                              状态栏和浮动歌词
```

应用会读取以下缓存位置：

```text
~/Library/Caches/com.apple.Music/Cache.db
~/Library/Caches/com.apple.Music/fsCachedData/
```

缓存响应通过歌曲名、歌手、专辑和时长进行匹配。缓存数据库始终以只读方式打开。
如果数据库结构无法识别，应用会降级扫描最近的缓存文件。

## 兼容性

- macOS 13 或更高版本
- Music.app
- Music.app 已缓存歌词响应的 Apple Music Catalog 歌曲

不保证任意导入的本地音乐文件都能使用。只有当 Music.app 同时缓存了与本地歌曲
匹配的 Apple Catalog `syllable-lyrics` 响应时，才可能显示歌词。macOS 也可能
随时清理这些缓存。

从源码构建还需要 Swift 5.9 或 Xcode 15 及更高版本。

## 构建和运行

直接运行 Swift Package：

```bash
./scripts/run.sh
```

创建本地签名的应用包：

```bash
./scripts/package-app.sh
open "dist/Apple Music Lyrics.app"
```

将生成的应用安装到当前电脑：

```bash
ditto "dist/Apple Music Lyrics.app" "/Applications/Apple Music Lyrics.app"
```

### 无法打开下载的应用

发布版本使用 ad-hoc 签名且尚未经过 Apple 公证，因此从浏览器下载后，macOS
可能提示应用“无法验证”或“已损坏”。请先确认应用来自本项目的官方 GitHub
Release，然后在终端中移除下载隔离属性并重新打开：

```bash
xattr -dr com.apple.quarantine "/Applications/Apple Music Lyrics.app"
open "/Applications/Apple Music Lyrics.app"
```

如果仍然无法打开，可以清除应用包的全部扩展属性：

```bash
xattr -cr "/Applications/Apple Music Lyrics.app"
```

也可以在 Finder 中右键应用并选择“打开”，或前往“系统设置 > 隐私与安全性”
选择“仍要打开”。不要对来源不明的应用执行上述命令。

## 自动发布

推送符合语义化版本格式的 Tag 后，GitHub Actions 会自动执行发布工作流：

```bash
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
```

工作流会运行测试，构建同时支持 `arm64` 和 `x86_64` 的 Universal 应用，并将
以下文件上传到 GitHub Release：

- `Apple-Music-Lyrics-<version>-macos-universal.zip`
- `Apple-Music-Lyrics-<version>-macos-universal.dmg`
- `SHA256SUMS.txt`

除非向打包脚本提供 `CODESIGN_IDENTITY`，发布版本默认使用 ad-hoc 签名。
ad-hoc 签名不能替代 Developer ID 签名和 Apple 公证，因此下载的应用仍可能显示
Gatekeeper 警告。

## 权限

首次启动时，请在以下位置允许 Apple Music Lyrics 控制 **Music**：

```text
系统设置 > 隐私与安全性 > 自动化
```

应用通过 macOS 的进程 API 判断 Music.app 是否正在运行，不需要控制
**System Events**。应用也不需要“完全磁盘访问”权限，不会读取 Apple 账户凭据。

### 播放歌曲时显示 Error

首次读取当前歌曲时，macOS 会询问是否允许 Apple Music Lyrics 控制 Music，
请选择“允许”。如果没有出现授权提示，或播放歌曲后仍显示 Error，请检查：

```text
系统设置 > 隐私与安全性 > 自动化 > Apple Music Lyrics > Music
```

如果“自动化”列表中没有 Apple Music Lyrics，请退出应用，在终端执行以下命令，
然后在重新出现的系统授权窗口中选择“允许”：

```bash
tccutil reset AppleEvents local.applemusiclyrics
open "/Applications/Apple Music Lyrics.app"
```

使用 ad-hoc 签名的应用在重新安装或升级后，可能需要重新授权。

## 菜单操作

| 操作 | 说明 |
| --- | --- |
| Show / Hide Floating Lyrics | 显示或隐藏浮动歌词面板（菜单聚焦时可按 `Command-L`） |
| Refresh Lyrics | 重新扫描 Music.app 的本地歌词缓存 |
| Quit Apple Music Lyrics | 退出应用 |

浮动面板的位置、尺寸和显示状态会在下次启动时恢复。

## 测试

运行确定性的解析器和数据源测试：

```bash
swift test
```

可选的集成测试会使用 Music.app 当前歌曲检查真实的本地缓存。请先播放一首已经
在 Music.app 中显示过歌词的 Catalog 歌曲，然后执行：

```bash
APPLE_MUSIC_CACHE_INTEGRATION=1 \
  swift test --filter AppleMusicCacheIntegrationTests
```

测试数据中不包含受版权保护的真实歌词。

## 项目结构

```text
Sources/AppleMusicLyrics/
  AppMain.swift                         应用入口
  AppDelegate.swift                     轮询和应用状态管理
  NowPlayingService.swift               Music.app AppleScript 集成
  AppleMusicCacheLyricsProvider.swift   缓存索引和歌曲匹配
  AppleTTMLParser.swift                 TTML 行级和词级时间解析
  KaraokeRenderer.swift                 浮动面板高亮渲染
  MenuBarController.swift               状态项和流畅歌词渲染
  FloatingLyricsWindow.swift            浮动歌词面板
  LyricsService.swift                   仅使用 Apple 数据的歌词服务
  Models.swift                          公共数据模型
  AppPreferences.swift                  UserDefaults 设置
  AppleScriptRunner.swift               AppleScript 执行工具

Tests/AppleMusicLyricsTests/             单元测试和可选集成测试
scripts/run.sh                           Release 构建和直接运行
scripts/package-app.sh                   本地应用包打包
scripts/create-release-artifacts.sh      Universal ZIP 和 DMG 生成
.github/workflows/release.yml            Tag 触发的 GitHub Release 工作流
```

## 已知限制

- Apple 没有通过受支持的公开 MusicKit API 提供歌词正文。
- 私有缓存数据库结构和 JSON 字段可能随时变化。
- Music.app 下载对应响应后，歌词才能显示。
- 缓存缺失时，本应用不会主动下载，只会重新扫描本地缓存。
- 状态栏项目无法使用 MacBook 刘海左侧的应用菜单区域。
- 应用使用本地 ad-hoc 签名，没有经过 Apple 公证。

## 参与贡献

欢迎提交问题和 Pull Request。开发和测试要求请参阅
[CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证和免责声明

源代码基于 [MIT License](LICENSE) 发布。

歌词和相关元数据的权利归各自权利人所有，不包含在本仓库的开源许可范围内。
本项目与 Apple Inc. 没有隶属、认可或赞助关系。Apple Music 是 Apple Inc. 的
商标。
