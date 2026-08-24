# KSPlayer 进度条预览与磁盘预缓存

## 目标

实现统一缩略图预览 API、UIKit/AppKit/SwiftUI 进度条预览、点播媒体磁盘预缓存，并保持现有 FFmpeg 依赖版本不变。

## 阶段

- [x] 勘察播放器、进度条、IO 与测试结构
- [x] 实现公共缩略图预览 API 与 AVPlayer/FFmpeg 生成逻辑
- [x] 实现点播媒体磁盘缓存、断点续传、状态与 LRU 清理
- [x] 接入 UIKit/AppKit/SwiftUI 进度条交互和预览浮层
- [x] 补充测试/fixture 并做静态验证

## 成功标准

- AVPlayer 与 FFmpeg 均暴露按时间排序的缩略图生成/单帧预览接口。
- 拖动进度条只更新预览，松手只执行一次最终 seek。
- 缓存默认关闭，仅缓存可 Range seek 的点播资源，支持部分文件续传、完整离线读取、活跃条目保护和 LRU 清理。
- 失败/取消/缺少视频轨道不影响正常播放；FFmpeg 依赖版本无变化。

## 决策

- 缓存目录为 `Library/Caches/KSPlayer/Media`，默认容量 512 MiB。
- 不复用现有 `KSOptions.cache` 字段。
- 本机无 `swift`/`xcodebuild`，采用静态检查与仓库可用工具验证。

## 当前风险

- 本机没有 Apple Swift 工具链，资源加载器、严格并发和跨平台条件编译需要后续静态复核。
- AVPlayer 自定义资源加载器在首次播放前做 Range 探测，服务器拒绝 Range 时回退原始 URL。
- 已完成静态复核；Apple SDK 相关构建和运行测试仍需 macOS CI 执行。
- 本次收口静态检查：UTF-8、条件编译平衡、大括号计数、`git diff --check` 均通过；本机仍无 Swift 工具链。

## 错误记录

| 错误 | 尝试 | 处理 |
|---|---:|---|
| PowerShell 字符串插值中的路径冒号触发变量解析错误 | 1 | 改用 `${path}:...` 形式重新执行，未影响源码 |
| `apply_patch` 目标路径遗漏 `Sources/KSPlayer` 前缀 | 1 | 修正为仓库内完整绝对路径，未修改源码 |
| PowerShell `foreach` 集合表达式不能直接用分号连接命令 | 1 | 改为先将两组路径保存到变量后再遍历，未影响源码 |
| 静态检查脚本首次使用 PowerShell 复合表达式导致解析错误 | 1 | 改为分步构造 `$paths` 后重新执行，检查已完成 |
