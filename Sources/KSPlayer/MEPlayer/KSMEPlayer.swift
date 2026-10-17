//
//  KSMEPlayer.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/9.
//

import AVFoundation
import AVKit
import Foundation
import Libavutil
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

public class KSMEPlayer: NSObject {
    private var recovery = PlaybackRecovery()
    private var recoveryWork: DispatchWorkItem?
    private var sessionGeneration: UInt64 = 0
    private var sessionActive = true
    private var deliveredReady = false
    private var deliveredFailure = false
    private var savedTrackIDs: [AVFoundation.AVMediaType: Set<Int32>]?
    private var savedRecoveryTime: TimeInterval?
    private var userHardwareDecode: Bool
    private var userAsyncDecode: Bool
    private var userStartPlayTime: TimeInterval
    private var userForwardBufferDuration: TimeInterval
    private var userMaxBufferDuration: TimeInterval
    public var subtitleDelay: TimeInterval = 0 {
        didSet {
            tracks(mediaType: .subtitle).compactMap { $0 as? FFmpegAssetTrack }.forEach {
                $0.delay = subtitleDelay
            }
            (videoOutput as? MetalPlayView)?.clearSubtitles()
        }
    }
    private var loopCount = 1
    private var playerItem: MEPlayerItem
    private var sourceURL: URL
    private let previewFramesLock = NSLock()
    private var previewFrames = [KSPlayerPreviewFrame]()
    public let audioOutput: AudioOutput
    private var options: KSOptions
    private var bufferingCountDownTimer: Timer?
    public private(set) var videoOutput: (VideoOutput & UIView)? {
        didSet {
            oldValue?.invalidate()
            runOnMainThread {
                oldValue?.removeFromSuperview()
            }
        }
    }

    public private(set) var bufferingProgress = 0 {
        willSet {
            runOnMainThread { [weak self] in
                guard let self else { return }
                delegate?.changeBuffering(player: self, progress: newValue)
            }
        }
    }

    private lazy var _pipController: Any? = {
        if #available(iOS 15.0, tvOS 15.0, macOS 12.0, *), let videoOutput {
            let contentSource = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: videoOutput.displayLayer, playbackDelegate: self)
            let pip = KSPictureInPictureController(contentSource: contentSource)
            return pip
        } else {
            return nil
        }
    }()

    @available(tvOS 14.0, *)
    public var pipController: KSPictureInPictureController? {
        guard (videoOutput as? MetalPlayView)?.supportsPictureInPicture == true else { return nil }
        return _pipController as? KSPictureInPictureController
    }

    private lazy var _playbackCoordinator: Any? = {
        if #available(macOS 12.0, iOS 15.0, tvOS 15.0, *) {
            let coordinator = AVDelegatingPlaybackCoordinator(playbackControlDelegate: self)
            coordinator.suspensionReasonsThatTriggerWaiting = [.stallRecovery]
            return coordinator
        } else {
            return nil
        }
    }()

    @available(macOS 12.0, iOS 15.0, tvOS 15.0, *)
    public var playbackCoordinator: AVPlaybackCoordinator {
        // swiftlint:disable force_cast
        _playbackCoordinator as! AVPlaybackCoordinator
        // swiftlint:enable force_cast
    }

    public private(set) var playableTime = TimeInterval(0)
    public weak var delegate: MediaPlayerDelegate?
    public private(set) var isReadyToPlay = false
    public var allowsExternalPlayback: Bool = false
    public var usesExternalPlaybackWhileExternalScreenIsActive: Bool = false

    public var playbackRate: Float = 1 {
        didSet {
            if playbackRate != audioOutput.playbackRate {
                audioOutput.playbackRate = playbackRate
                if audioOutput is AudioUnitPlayer {
                    var audioFilters = options.audioFilters.filter {
                        !$0.hasPrefix("atempo=")
                    }
                    if playbackRate != 1 {
                        audioFilters.append("atempo=\(playbackRate)")
                    }
                    options.audioFilters = audioFilters
                }
            }
        }
    }

    public private(set) var loadState = MediaLoadState.idle {
        didSet {
            if loadState != oldValue {
                playOrPause()
            }
        }
    }

    public private(set) var playbackState = MediaPlaybackState.idle {
        didSet {
            if playbackState != oldValue {
                playOrPause()
                if playbackState == .finished {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.delegate?.finish(player: self, error: nil)
                    }
                }
            }
        }
    }

    public required init(url: URL, options: KSOptions) {
        userHardwareDecode = options.hardwareDecode
        userAsyncDecode = options.asynchronousDecompression
        userStartPlayTime = options.startPlayTime
        userForwardBufferDuration = options.preferredForwardBufferDuration
        userMaxBufferDuration = options.maxBufferDuration
        KSOptions.setAudioSession()
        audioOutput = KSOptions.audioPlayerType.init()
        playerItem = MEPlayerItem(url: url, options: options)
        sourceURL = url
        if options.videoDisable {
            videoOutput = nil
        } else {
            videoOutput = KSOptions.videoPlayerType.init(options: options)
        }
        self.options = options
        super.init()
        playerItem.delegate = self
        audioOutput.renderSource = playerItem
        videoOutput?.renderSource = playerItem
        videoOutput?.displayLayerDelegate = self
        connectSubtitleRenderer()
        #if !os(macOS)
        NotificationCenter.default.addObserver(self, selector: #selector(audioRouteChange), name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance())
        if #available(tvOS 15.0, iOS 15.0, *) {
            NotificationCenter.default.addObserver(self, selector: #selector(spatialCapabilityChange), name: AVAudioSession.spatialPlaybackCapabilitiesChangedNotification, object: nil)
        }
        #endif
    }

    deinit {
        recoveryWork?.cancel()
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(2)
        #endif
        NotificationCenter.default.removeObserver(self)
        videoOutput?.invalidate()
        playerItem.shutdown()
    }
}

// MARK: - private functions

private extension KSMEPlayer {
    func playOrPause() {
        runOnMainThread { [weak self] in
            guard let self else { return }
            let isPaused = !(self.playbackState == .playing && self.loadState == .playable)
            if isPaused {
                self.audioOutput.pause()
                self.videoOutput?.pause()
            } else {
                self.audioOutput.play()
                self.videoOutput?.play()
            }
            self.delegate?.changeLoadState(player: self)
        }
    }

    @objc private func spatialCapabilityChange(notification _: Notification) {
        KSLog("[audio] spatialCapabilityChange")
        for track in tracks(mediaType: .audio) {
            (track as? FFmpegAssetTrack)?.audioDescriptor?.updateAudioFormat()
        }
    }

    #if !os(macOS)
    @objc private func audioRouteChange(notification: Notification) {
        KSLog("[audio] audioRouteChange")
        guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else {
            return
        }
//        let routeChangeReason = AVAudioSession.RouteChangeReason(rawValue: reason)
//        guard [AVAudioSession.RouteChangeReason.newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange].contains(routeChangeReason) else {
//            return
//        }
        for track in tracks(mediaType: .audio) {
            (track as? FFmpegAssetTrack)?.audioDescriptor?.updateAudioFormat()
        }
        audioOutput.flush()
    }
    #endif
}

extension KSMEPlayer: MEPlayerDelegate {
    func sourceDidOpened(source: MEPlayerItem) {
        let generation = sessionGeneration
        runOnMainThread { [weak self] in
            guard let self, self.sessionActive, generation == self.sessionGeneration, source === self.playerItem else { return }
            savedTrackIDs = nil
            savedRecoveryTime = nil
            isReadyToPlay = true
            tracks(mediaType: .subtitle).compactMap { $0 as? FFmpegAssetTrack }.forEach {
                $0.delay = self.subtitleDelay
            }
            options.readyTime = CACurrentMediaTime()
            let vidoeTracks = tracks(mediaType: .video)
            if vidoeTracks.isEmpty {
                videoOutput = nil
            }
            let audioDescriptor = tracks(mediaType: .audio).first { $0.isEnabled }.flatMap {
                $0 as? FFmpegAssetTrack
            }?.audioDescriptor
            runOnMainThread { [weak self] in
                guard let self else { return }
                if let audioDescriptor {
                    KSLog("[audio] audio type: \(audioOutput) prepare audioFormat )")
                    audioOutput.prepare(audioFormat: audioDescriptor.audioFormat)
                }
                if let controlTimebase = videoOutput?.displayLayer.controlTimebase, options.startPlayTime > 1 {
                    CMTimebaseSetTime(controlTimebase, time: CMTimeMake(value: Int64(options.startPlayTime), timescale: 1))
                }
                guard !deliveredReady else { return }
                deliveredReady = true
                delegate?.readyToPlay(player: self)
            }
        }
    }

    func sourceDidFailed(source: MEPlayerItem, error: NSError?) {
        let generation = sessionGeneration
        runOnMainThread { [weak self] in
            guard let self, self.sessionActive, generation == self.sessionGeneration, source === self.playerItem else { return }
            runOnMainThread { [weak self] in
                guard let self else { return }
                guard !self.deliveredFailure else { return }
                if let error, self.recover(error: error) { return }
                self.finishFailure(error)
            }
        }
    }

    func sourceDidFinished(source: MEPlayerItem) {
        let generation = sessionGeneration
        runOnMainThread { [weak self] in
            guard let self, self.sessionActive, !self.deliveredFailure, generation == self.sessionGeneration, source === self.playerItem else { return }
            runOnMainThread { [weak self] in
                guard let self else { return }
                if self.isLive, KSOptions.isStreamingURL(self.sourceURL) {
                    let error = NSError(errorCode: .readFrame, avErrorCode: -Int32(EIO))
                    if self.recover(error: error) { return }
                    self.finishFailure(error)
                    return
                }
                if self.options.isLoopPlay {
                    self.loopCount += 1
                    self.delegate?.playBack(player: self, loopCount: self.loopCount)
                    self.audioOutput.play()
                    self.videoOutput?.play()
                } else {
                    self.playbackState = .finished
                }
            }
        }
    }

    func sourceDidChange(source: MEPlayerItem, loadingState: LoadingState) {
        let generation = sessionGeneration
        runOnMainThread { [weak self] in
            guard let self, self.sessionActive, generation == self.sessionGeneration, source === self.playerItem else { return }
            if loadingState.isEndOfFile {
                playableTime = duration
            } else {
                playableTime = currentPlaybackTime + loadingState.loadedTime
            }
            if loadState == .playable {
                if !loadingState.isEndOfFile, loadingState.frameCount == 0, loadingState.packetCount == 0, options.preferredForwardBufferDuration != 0 {
                    loadState = .loading
                    if playbackState == .playing {
                        runOnMainThread { [weak self] in
                            // 在主线程更新进度
                            self?.bufferingProgress = 0
                        }
                    }
                }
            } else {
                if loadingState.isFirst {
                    if videoOutput?.pixelBuffer == nil {
                        videoOutput?.readNextFrame()
                    }
                }
                var progress = 100
                if loadingState.isPlayable {
                    loadState = .playable
                } else {
                    if loadingState.progress.isInfinite {
                        progress = 100
                    } else if loadingState.progress.isNaN {
                        progress = 0
                    } else {
                        progress = min(100, Int(loadingState.progress))
                    }
                }
                if playbackState == .playing {
                    runOnMainThread { [weak self] in
                        // 在主线程更新进度
                        self?.bufferingProgress = progress
                    }
                }
            }
            if duration == 0, playbackState == .playing, loadState == .playable {
                if let rate = options.liveAdaptivePlaybackRate(loadingState: loadingState) {
                    playbackRate = rate
                }
            }
        }
    }

    func sourceDidChange(source: MEPlayerItem, oldBitRate: Int64, newBitrate: Int64) {
        let generation = sessionGeneration
        runOnMainThread { [weak self] in
            guard let self, self.sessionActive, generation == self.sessionGeneration, source === self.playerItem else { return }
            KSLog("oldBitRate \(oldBitRate) change to newBitrate \(newBitrate)")

        }
    }
}

extension KSMEPlayer: MediaPlayerProtocol {
    public var chapters: [Chapter] {
        playerItem.chapters
    }

    public var subtitleDataSouce: SubtitleDataSouce? { self }
    public var playbackVolume: Float {
        get {
            audioOutput.volume
        }
        set {
            audioOutput.volume = newValue
        }
    }

    public var isPlaying: Bool { playbackState == .playing }

    @MainActor
    public var naturalSize: CGSize {
        options.display == .plane ? playerItem.naturalSize : KSOptions.sceneSize
    }

    public var isExternalPlaybackActive: Bool { false }

    public var view: UIView? { videoOutput }

    public func replace(url: URL, options: KSOptions) {
        KSLog("replaceUrl \(self)")
        setPreviewFrames([])
        shutdown()
        playerItem.delegate = nil
        playerItem = MEPlayerItem(url: url, options: options)
        sourceURL = url
        if options.videoDisable {
            videoOutput = nil
        } else if videoOutput == nil {
            videoOutput = KSOptions.videoPlayerType.init(options: options)
            videoOutput?.displayLayerDelegate = self
        }
        self.options = options
        userHardwareDecode = options.hardwareDecode
        userAsyncDecode = options.asynchronousDecompression
        userStartPlayTime = options.startPlayTime
        userForwardBufferDuration = options.preferredForwardBufferDuration
        userMaxBufferDuration = options.maxBufferDuration
        sessionActive = true
        deliveredReady = false
        deliveredFailure = false
        recovery = PlaybackRecovery()
        savedTrackIDs = nil
        savedRecoveryTime = nil
        playerItem.delegate = self
        audioOutput.flush()
        audioOutput.renderSource = playerItem
        videoOutput?.renderSource = playerItem
        videoOutput?.options = options
        connectSubtitleRenderer()
    }

    public var currentPlaybackTime: TimeInterval {
        get {
            playerItem.currentPlaybackTime
        }
        set {
            seek(time: newValue) { _ in }
        }
    }

    /// 见 `MEPlayerItem.displayedVideoTime`——最近一帧绘制到 display layer 的 PTS，
    /// 适合驱动需要与画面严格同步的视图（audioClock 因 buffer prefill 跑在画面之前不适用）。
    public var displayedVideoTime: TimeInterval { playerItem.displayedVideoTime }

    public var duration: TimeInterval { playerItem.duration }

    public var fileSize: Double { playerItem.fileSize }

    public var seekable: Bool { sessionActive && isReadyToPlay && playerItem.seekable }
    public var isLive: Bool { playerItem.isLive }
    public var runtimeInfo: [String: String] {
        let output = videoOutput as? MetalPlayView
        let track = tracks(mediaType: .video).first { $0.isEnabled } as? FFmpegAssetTrack
        return ["ffmpegVersion": String(cString: av_version_info()),
                "decoder": track?.actualDecoder ?? "unknown",
                "displayBackend": output?.actualRenderingBackend ?? "none",
                "inputDynamicRange": output?.inputDynamicRange ?? "unknown",
                "outputDynamicRange": output?.outputDynamicRange ?? "unknown",
                "dolbyProfile": (output?.doviProfile ?? track?.dovi.map { Int($0.dv_profile) }).map(String.init) ?? "none",
                "isLive": String(isLive), "seekable": String(seekable)]
    }

    public var dynamicInfo: DynamicInfo? {
        playerItem.dynamicInfo
    }

    public func seek(time: TimeInterval, completion: @escaping ((Bool) -> Void)) {
        guard seekable, sessionActive, recoveryWork == nil else { completion(false); return }
        let generation = sessionGeneration
        (videoOutput as? MetalPlayView)?.clearSubtitles()
        let time = max(time, 0)
        playbackState = .seeking
        runOnMainThread { [weak self] in
            guard let self, self.sessionGeneration == generation, self.sessionActive else { return }
            self.bufferingProgress = 0
        }
        let seekTime: TimeInterval
        if time >= duration, options.isLoopPlay {
            seekTime = 0
        } else {
            seekTime = time
        }
        playerItem.seek(time: seekTime) { [weak self] result in
            guard let self, generation == self.sessionGeneration, self.sessionActive else { completion(false); return }
            if result {
                self.audioOutput.flush()
                runOnMainThread { [weak self] in
                    guard let self, self.sessionGeneration == generation, self.sessionActive else { return }
                    if let controlTimebase = self.videoOutput?.displayLayer.controlTimebase {
                        CMTimebaseSetTime(controlTimebase, time: CMTimeMake(value: Int64(self.currentPlaybackTime), timescale: 1))
                    }
                }
            }
            completion(result)
        }
    }

    public func prepareToPlay() {
        KSLog("prepareToPlay \(self)")
        if !sessionActive {
            sessionActive = true
            deliveredReady = false
            deliveredFailure = false
            recovery = PlaybackRecovery()
            playerItem = MEPlayerItem(url: sourceURL, options: options)
            playerItem.delegate = self
            audioOutput.renderSource = playerItem
            videoOutput?.renderSource = playerItem
        }
        options.prepareTime = CACurrentMediaTime()
        playerItem.prepareToPlay()
        bufferingProgress = 0
    }

    public func play() {
        KSLog("play \(self)")
        playbackState = .playing
        if #available(iOS 15.0, tvOS 15.0, macOS 12.0, *) {
            pipController?.invalidatePlaybackState()
        }
    }

    public func pause() {
        KSLog("pause \(self)")
        playbackState = .paused
        if #available(iOS 15.0, tvOS 15.0, macOS 12.0, *) {
            pipController?.invalidatePlaybackState()
        }
    }

    public func shutdown() {
        sessionGeneration &+= 1
        sessionActive = false
        recoveryWork?.cancel()
        recoveryWork = nil
        savedTrackIDs = nil
        savedRecoveryTime = nil
        playerItem.delegate = nil
        (videoOutput as? MetalPlayView)?.clearSubtitles()
        options.hardwareDecode = userHardwareDecode
        options.asynchronousDecompression = userAsyncDecode
        options.startPlayTime = userStartPlayTime
        options.preferredForwardBufferDuration = userForwardBufferDuration
        options.maxBufferDuration = userMaxBufferDuration
        KSLog("shutdown \(self)")
        playbackState = .stopped
        loadState = .idle
        isReadyToPlay = false
        loopCount = 0
        playerItem.shutdown()
        options.prepareTime = 0
        options.dnsStartTime = 0
        options.tcpStartTime = 0
        options.tcpConnectedTime = 0
        options.openTime = 0
        options.findTime = 0
        options.readyTime = 0
        options.readAudioTime = 0
        options.readVideoTime = 0
        options.decodeAudioTime = 0
        options.decodeVideoTime = 0
        if KSOptions.isClearVideoWhereReplace {
            videoOutput?.flush()
        }
    }

    @MainActor
    public var contentMode: UIViewContentMode {
        get {
            view?.contentMode ?? .center
        }
        set {
            view?.contentMode = newValue
        }
    }

    public func thumbnailImageAtCurrentTime() async -> CGImage? {
        guard !isLive, (videoOutput as? MetalPlayView)?.requiresMetal != true else { return nil }
        return videoOutput?.pixelBuffer?.cgImage()
    }

    public func generatePreviewThumbnails() async throws -> [KSPlayerPreviewFrame] {
        try await generatePreviewThumbnails(onUpdate: { _ in })
    }

    public func generatePreviewThumbnails(onUpdate: @escaping ([KSPlayerPreviewFrame]) -> Void) async throws -> [KSPlayerPreviewFrame] {
        guard seekable, !isLive else { return [] }
        let generation = sessionGeneration
        try Task.checkCancellation()
        let thumbnails = try await ThumbnailController().generateThumbnail(for: sourceURL, onUpdate: { [weak self] thumbnails in
            guard let self, self.sessionActive, self.sessionGeneration == generation else { return }
            let frames = self.previewFrames(from: thumbnails)
            self.setPreviewFrames(frames)
            onUpdate(frames)
        })
        guard sessionActive, sessionGeneration == generation else { throw CancellationError() }
        let frames = previewFrames(from: thumbnails)
        setPreviewFrames(frames)
        onUpdate(frames)
        return frames
    }

    private func previewFrames(from thumbnails: [FFThumbnail]) -> [KSPlayerPreviewFrame] {
        thumbnails.compactMap { thumbnail in
            thumbnail.cgImage.map { KSPlayerPreviewFrame(time: thumbnail.time, image: $0) }
        }.sorted { $0.time < $1.time }
    }

    public func previewImage(at time: TimeInterval) async -> CGImage? {
        guard seekable, !isLive, time.isFinite, time >= 0 else { return nil }
        if let frame = previewFramesSnapshot().min(by: { abs($0.time - time) < abs($1.time - time) }) {
            return frame.image
        }
        return (try? await ThumbnailController(thumbnailCount: 1).generateThumbnail(for: sourceURL, at: time))?.first?.cgImage
    }

    private func setPreviewFrames(_ frames: [KSPlayerPreviewFrame]) {
        previewFramesLock.lock()
        previewFrames = frames
        previewFramesLock.unlock()
    }

    private func previewFramesSnapshot() -> [KSPlayerPreviewFrame] {
        previewFramesLock.lock()
        let frames = previewFrames
        previewFramesLock.unlock()
        return frames
    }

    public func enterBackground() {}

    public func enterForeground() {}

    public var isMuted: Bool {
        get {
            audioOutput.isMuted
        }
        set {
            audioOutput.isMuted = newValue
        }
    }

    public func tracks(mediaType: AVFoundation.AVMediaType) -> [MediaPlayerTrack] {
        guard sessionActive, isReadyToPlay else { return [] }
        return playerItem.assetTracks.compactMap { track -> MediaPlayerTrack? in
            if track.mediaType == mediaType {
                return track
            } else if mediaType == .subtitle {
                return track.closedCaptionsTrack
            }
            return nil
        }
    }

    public func select(track: some MediaPlayerTrack) {
        if track.mediaType == .subtitle { (videoOutput as? MetalPlayView)?.clearSubtitles() }
        let isSeek = playerItem.select(track: track)
        if isSeek {
            audioOutput.flush()
        }
    }
}

@available(tvOS 14.0, *)
extension KSMEPlayer: AVPictureInPictureSampleBufferPlaybackDelegate {
    public func pictureInPictureController(_: AVPictureInPictureController, setPlaying playing: Bool) {
        playing ? play() : pause()
    }

    public func pictureInPictureControllerTimeRangeForPlayback(_: AVPictureInPictureController) -> CMTimeRange {
        // Handle live streams.
        if duration == 0 {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        return CMTimeRange(start: 0, end: duration)
    }

    public func pictureInPictureControllerIsPlaybackPaused(_: AVPictureInPictureController) -> Bool {
        !isPlaying
    }

    public func pictureInPictureController(_: AVPictureInPictureController, didTransitionToRenderSize _: CMVideoDimensions) {}
    public func pictureInPictureController(_: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {
        seek(time: currentPlaybackTime + skipInterval.seconds) { _ in }
    }

    public func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_: AVPictureInPictureController) -> Bool {
        false
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, *)
extension KSMEPlayer: AVPlaybackCoordinatorPlaybackControlDelegate {
    public func playbackCoordinator(_: AVDelegatingPlaybackCoordinator, didIssue playCommand: AVDelegatingPlaybackCoordinatorPlayCommand, completionHandler: @escaping () -> Void) {
        guard playCommand.expectedCurrentItemIdentifier == (playbackCoordinator as? AVDelegatingPlaybackCoordinator)?.currentItemIdentifier else {
            completionHandler()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            if self.playbackState != .playing {
                self.play()
            }
            completionHandler()
        }
    }

    public func playbackCoordinator(_: AVDelegatingPlaybackCoordinator, didIssue pauseCommand: AVDelegatingPlaybackCoordinatorPauseCommand, completionHandler: @escaping () -> Void) {
        guard pauseCommand.expectedCurrentItemIdentifier == (playbackCoordinator as? AVDelegatingPlaybackCoordinator)?.currentItemIdentifier else {
            completionHandler()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            if self.playbackState != .paused {
                self.pause()
            }
            completionHandler()
        }
    }

    public func playbackCoordinator(_: AVDelegatingPlaybackCoordinator, didIssue seekCommand: AVDelegatingPlaybackCoordinatorSeekCommand) async {
        guard seekCommand.expectedCurrentItemIdentifier == (playbackCoordinator as? AVDelegatingPlaybackCoordinator)?.currentItemIdentifier else {
            return
        }
        let seekTime = fmod(seekCommand.itemTime.seconds, duration)
        if abs(currentPlaybackTime - seekTime) < CGFLOAT_EPSILON {
            return
        }
        seek(time: seekTime) { _ in }
    }

    public func playbackCoordinator(_: AVDelegatingPlaybackCoordinator, didIssue bufferingCommand: AVDelegatingPlaybackCoordinatorBufferingCommand, completionHandler: @escaping () -> Void) {
        guard bufferingCommand.expectedCurrentItemIdentifier == (playbackCoordinator as? AVDelegatingPlaybackCoordinator)?.currentItemIdentifier else {
            completionHandler()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            guard self.loadState != .playable, let countDown = bufferingCommand.completionDueDate?.timeIntervalSinceNow else {
                completionHandler()
                return
            }
            self.bufferingCountDownTimer?.invalidate()
            self.bufferingCountDownTimer = nil
            self.bufferingCountDownTimer = Timer(timeInterval: countDown, repeats: false) { _ in
                completionHandler()
            }
        }
    }
}

extension KSMEPlayer: DisplayLayerDelegate {
    public func renderingBackendDidChange() {
        if (videoOutput as? MetalPlayView)?.requiresMetal == true {
            if #available(iOS 15.0, tvOS 15.0, macOS 12.0, *) {
                (_pipController as? KSPictureInPictureController)?.stopPictureInPicture()
            }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.changeLoadState(player: self)
        }
    }

    public func change(displayLayer: AVSampleBufferDisplayLayer) {
        if #available(iOS 15.0, tvOS 15.0, macOS 12.0, *) {
            let contentSource = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
            _pipController = KSPictureInPictureController(contentSource: contentSource)
            // 更改contentSource会直接crash
//            pipController?.contentSource = contentSource
        }
    }
}

public extension KSMEPlayer {
    func startRecord(url: URL) {
        playerItem.startRecord(url: url)
    }

    func stoptRecord() {
        playerItem.stopRecord()
    }
}

private extension KSMEPlayer {
    func finishFailure(_ error: NSError?) {
        deliveredFailure = true
        sessionActive = false
        sessionGeneration &+= 1
        isReadyToPlay = false
        playerItem.delegate = nil
        playerItem.shutdown()
        playbackState = .stopped
        loadState = .idle
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.finish(player: self, error: error)
        }
    }

    func connectSubtitleRenderer() {
        (videoOutput as? MetalPlayView)?.imageSubtitleProvider = { [weak self] in
            guard let self, self.sessionActive, self.isReadyToPlay else { return [] }
            return self.tracks(mediaType: .subtitle).compactMap { $0 as? FFmpegAssetTrack }
                .filter { $0.isEnabled && $0.isImageSubtitle }
                .flatMap { $0.search(for: self.displayedVideoTime - $0.delay) }
        }
    }

    func recover(error: NSError) -> Bool {
        let hardware = options.hardwareDecode && (error.code == KSPlayerErrorCode.codesContextOpen.rawValue ||
            tracks(mediaType: .video).contains { ($0 as? FFmpegAssetTrack)?.actualDecoder?.hasPrefix("VideoToolbox") == true })
        guard let action = recovery.next(error: error, streaming: KSOptions.isStreamingURL(sourceURL),
                                         hardware: hardware)
        else { return false }
        if savedTrackIDs == nil, isReadyToPlay {
            savedTrackIDs = Dictionary(uniqueKeysWithValues: [AVMediaType.video, .audio, .subtitle].map { type in
                (type, Set(tracks(mediaType: type).filter { $0.isEnabled }.map(\.trackID)))
            })
            savedRecoveryTime = seekable ? currentPlaybackTime : 0
        }
        if savedRecoveryTime == nil { savedRecoveryTime = options.startPlayTime }
        if action == .softwareDecode {
            options.hardwareDecode = false
            options.asynchronousDecompression = false
        }
        let delay: TimeInterval
        if case let .reconnect(seconds) = action { delay = seconds } else { delay = 0 }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        playerItem.delegate = nil
        playerItem.shutdown()
        isReadyToPlay = false
        loadState = .loading
        audioOutput.flush()
        videoOutput?.flush()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.sessionActive, self.sessionGeneration == generation else { return }
            self.recoveryWork = nil
            self.options.startPlayTime = self.savedRecoveryTime ?? 0
            self.playerItem = MEPlayerItem(url: self.sourceURL, options: self.options)
            self.playerItem.restoredTrackIDs = self.savedTrackIDs ?? [:]
            self.playerItem.delegate = self
            self.audioOutput.renderSource = self.playerItem
            self.videoOutput?.renderSource = self.playerItem
            self.playerItem.prepareToPlay()
        }
        recoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return true
    }

}

public extension KSMEPlayer {
    /// nil disables embedded subtitles. Existing text consumers use subtitleDataSouce.
    func setSubtitleTrack(_ track: (any MediaPlayerTrack)?) {
        tracks(mediaType: .subtitle).forEach { $0.isEnabled = false }
        if let track { select(track: track) }
        (videoOutput as? MetalPlayView)?.clearSubtitles()
    }
}
