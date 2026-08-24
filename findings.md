# 调研发现

## 当前结构

- `MediaPlayerProtocol` 只有 `thumbnailImageAtCurrentTime()`，需要补充统一的预览模型与 API。
- FFmpeg 侧已有 `ThumbnailController`，可按时间生成缩略图；`KSMEPlayer` 目前只返回当前 `pixelBuffer`。
- AVPlayer 使用 `AVAssetImageGenerator`，适合作为单帧和批量预览实现。
- `AbstractAVIOContext` 已存在，是接入 FFmpeg 自定义缓存 IO 的基础。
- `KSSlider` 已提供 `.touchDown`、`.valueChanged`、`.touchUpInside` 事件。
- SwiftUI 进度条位于 `VideoTimeShowView`。
- 测试资源缺少 `h264.mp4`、`mjpeg.flac`、`hevc.mkv`，现有测试可能静默跳过。
- `KSPlayerLayer` 是 UI 与播放器的统一编排入口，当前公开 `seek(time:autoPlay:completion:)`，可增加透传预览 API。
- `KSOptions` 有 `process(url:) -> AbstractAVIOContext?` 扩展点，且 `cache` 是已有 FFmpeg 语义，不能复用。
- `KSAVPlayer` 的 `urlAsset` 为私有 `AVURLAsset`，当前 `prepareToPlay()` 直接构造 `AVPlayerItem(asset:)`。
- `KSMEPlayer` 的 `playerItem` 为私有 `MEPlayerItem`，FFmpeg 缩略图可优先复用已解码帧；完整按时间生成需要基于现有 `ThumbnailController`。
- `PlayerView.slider` 已经将 `.valueChanged` 与 `.touchUpInside` 分开；当前 `.valueChanged` 只更新标签，`.touchUpInside` 才 seek，因此预览浮层可在现有事件链中接入。
- SwiftUI `VideoTimeShowView` 当前拖动时暂停、松手 seek；可增加 `@State` 预览帧和拖动时间，但 tvOS/xrOS 需继续保持无浮层。
- `KSSlider` 的 UIKit 事件含 touch cancel/outside，AppKit 当前只有松手事件；公共预览 API 与 UIKit 交互可先完整接入，AppKit 用现有松手路径显示/清理浮层。
- AVPlayer 预览在生成前异步加载 `tracks` / `duration`，生成失败或没有视频轨道时只返回预览错误，不改变播放状态。
- 媒体缓存的 `.part` 文件始终由共享锁串行写入，`.complete` 只作为完整性标记；短读会按服务端实际返回长度返回，避免文件尾读取失败。
- FFmpeg 缩略图时长按流时间基计算；短视频中 `duration / 100` 可能为 0，需要按有效采样数取整，避免 100 次重复 seek 到同一时间。
- UIKit `KSSlider` 原先把 `touchUpInside`、`touchCancel`、`touchUpOutside` 共用一个回调，无法保证取消拖动不触发最终 seek；应拆分取消事件。
- AppKit 的 `NSImage` 初始化需要显式传入 `size`，不能直接使用 UIKit 风格的 `NSImage(cgImage:)`。

## 约束

- 用户计划明确暂不升级 FFmpeg，当前 SPM 为 `6.1.4`，CocoaPods lock 为 `6.1.0`。
- `.codegraph/` 是用户已有未跟踪内容，必须保留且不修改。

## 验证限制

- Windows 工作区没有 Apple Swift 工具链，因此无法在本机执行 `swift build`、单元测试或 Demo 构建；已完成 UTF-8、条件编译/括号平衡、`git diff --check` 与依赖版本静态检查。
