# iOS FFmpeg 8.1 组件分支

此分支直接维护 KSPlayer 源码，以 `fb782b6f93bef9b68181a0d41e9dd22ef53d715b` 为基线。先在同级 FFmpegKit 仓库执行 `python3 iOSNative/build.py build`，再通过本地 CocoaPods 或 Swift Package 使用组件。最低 iOS 16；本分支不提供其它 Apple 平台的二进制。应用仓库中的旧升级方案已经回退，本次不改应用源码和发布入口。

## 通过现有 URL 接口播放

```swift
let options = KSOptions()
let player = KSMEPlayer(url: streamURL, options: options)
player.prepareToPlay()
player.play()
```

`KSPlayerLayer` 将 SRT、RTSP、RTMP 及其 TLS 变体路由到 KSMEPlayer。RTSP 默认 TCP，可用 `formatContextOptions["rtsp_transport"]` 显式覆盖。SRT URL 原样传给 FFmpeg，caller 使用 FFmpeg 默认模式或 URL 的 `mode=caller`。连接和读取默认分别限时 5 秒、10 秒；网络阶段的瞬态错误最多重连三次，等待 1、2、4 秒。明确的硬解终止错误只允许一次软件解码重开。损坏码流和缺失 Dolby RPU 不触发硬解恢复。

恢复保留原 options、请求头、倍速、播放/暂停状态、可定位内容的播放位置及已选轨道。直播没有历史位置恢复、seek 和预览缩略图，起播缓冲为 1 秒、上限为 5 秒。停止、替换媒体、释放对象会取消重连；旧来源实例与旧会话代次的回调被过滤。恢复成功不重复发送 `readyToPlay`。

非 HLS 的 H.264 使用 FFmpeg 解码后的 `best_effort_timestamp`，避免直接 VideoToolbox 按缺失 composition offset 的 packet 时间戳显示。保留现有 HEVC 场序和 HLS 策略。

## 查询实际显示能力

```swift
let diagnostics = player.runtimeInfo
let canSeek = player.seekable
let live = player.isLive
player.subtitleDelay = 0.25
player.setSubtitleTrack(selectedSubtitle) // nil 关闭内嵌字幕
```

运行信息包含 FFmpeg 版本、实际视频解码器、显示后端、输入/输出动态范围、Dolby profile、直播及可定位状态。字幕延迟单位为秒，正数使字幕延后；文本字幕继续走 `subtitleDataSouce`，PGS 等图形字幕由原生视频视图覆盖层显示，切轨、关闭、seek 和重开清空旧图像。

Profile 5/8 的逐帧 RPU/映射元数据按值复制，Metal 执行 reshape、矩阵变换与输出转换。Profile 7 使用基础层，不重建 FEL。屏幕支持时输出 HDR；SDR 使用 BT.2390。系统 sample buffer 路径沿用系统 HDR 处理。Metal 路径不提供画中画，切换到 Metal 时停止既有画中画并通知能力更新。图形字幕覆盖层不进入系统画中画画面；网络协议不支持 AVPlayer 的远端 AirPlay URL 播放。

## 验证边界

`PlaybackRecoveryTest.swift` 覆盖恢复预算、错误分类、协议默认值、RPU 内存复制及停止后回调过滤，需 macOS 执行 XCTest。FFmpegKit 的同源色彩测试从实际 Metal 函数编译 CPU 适配器，不能替代 GPU、Apple SDK 编译或真机 HDR 验收。SenPlayer 的精确 KSPlayer 提交、默认选路和完整 Dolby 支持范围仍未知。
