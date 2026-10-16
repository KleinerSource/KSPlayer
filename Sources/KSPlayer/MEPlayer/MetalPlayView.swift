//
//  MetalPlayView.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/11.
//

import AVFoundation
import Combine
import CoreMedia
#if canImport(MetalKit)
import MetalKit
#endif
public protocol DisplayLayerDelegate: NSObjectProtocol {
    func change(displayLayer: AVSampleBufferDisplayLayer)
    func renderingBackendDidChange()
}

public extension DisplayLayerDelegate {
    func renderingBackendDidChange() {}
}

public protocol VideoOutput: FrameOutput {
    var displayLayerDelegate: DisplayLayerDelegate? { get set }
    var options: KSOptions { get set }
    var displayLayer: AVSampleBufferDisplayLayer { get }
    var pixelBuffer: PixelBufferProtocol? { get }
    init(options: KSOptions)
    func invalidate()
    func readNextFrame()
}

public final class MetalPlayView: UIView, VideoOutput {
    public var displayLayer: AVSampleBufferDisplayLayer {
        displayView.displayLayer
    }

    private var isDovi: Bool = false
    private var formatDescription: CMFormatDescription? {
        didSet {
            options.updateVideo(refreshRate: fps, isDovi: isDovi, formatDescription: formatDescription)
        }
    }

    private var fps = Float(60) {
        didSet {
            if fps != oldValue {
                if KSOptions.preferredFrame {
                    let preferredFramesPerSecond = ceil(fps)
                    if #available(iOS 15.0, tvOS 15.0, macOS 14.0, *) {
                        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: preferredFramesPerSecond, maximum: 2 * preferredFramesPerSecond, __preferred: preferredFramesPerSecond)
                    } else {
                        displayLink.preferredFramesPerSecond = Int(preferredFramesPerSecond) << 1
                    }
                }
                options.updateVideo(refreshRate: fps, isDovi: isDovi, formatDescription: formatDescription)
            }
        }
    }

    public private(set) var pixelBuffer: PixelBufferProtocol?
    public private(set) var actualRenderingBackend = "sampleBuffer"
    public private(set) var inputDynamicRange = "sdr"
    public private(set) var outputDynamicRange = "sdr"
    public private(set) var doviProfile: Int?
    public private(set) var requiresMetal = false
    public var supportsPictureInPicture: Bool { pixelBuffer != nil && !requiresMetal }
    /// 用displayLink会导致锁屏无法draw，
    /// 用DispatchSourceTimer的话，在播放4k视频的时候repeat的时间会变长,
    /// 用MTKView的draw(in:)也是不行，会卡顿
    private var displayLink: CADisplayLink!
//    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    public var options: KSOptions
    public weak var renderSource: OutputRenderSourceDelegate?
    // AVSampleBufferAudioRenderer AVSampleBufferRenderSynchronizer AVSampleBufferDisplayLayer
    var displayView = AVSampleBufferDisplayView() {
        didSet {
            displayLayerDelegate?.change(displayLayer: displayView.displayLayer)
        }
    }

    private let metalView = MetalView()
    var imageSubtitleProvider: (() -> [SubtitlePart])?
    private let subtitleLayer = CALayer()
    private var subtitleTimer: Timer?
    public weak var displayLayerDelegate: DisplayLayerDelegate?
    public init(options: KSOptions) {
        self.options = options
        super.init(frame: .zero)
        addSubview(displayView)
        addSubview(metalView)
        #if os(macOS)
        subtitleLayer.isGeometryFlipped = true
        #endif
        subtitleLayer.masksToBounds = true
        backingLayer?.addSublayer(subtitleLayer)
        subtitleTimer = .scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateImageSubtitles()
        }
        metalView.isHidden = true
        //        displayLink = CADisplayLink(block: renderFrame)
        displayLink = CADisplayLink(target: self, selector: #selector(renderFrame))
        // 一定要用common。不然在视频上面操作view的话，那就会卡顿了。
        displayLink.add(to: .main, forMode: .common)
        pause()
    }

    public func play() {
        displayLink.isPaused = false
    }

    public func pause() {
        displayLink.isPaused = true
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        subview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            subview.leftAnchor.constraint(equalTo: leftAnchor),
            subview.topAnchor.constraint(equalTo: topAnchor),
            subview.bottomAnchor.constraint(equalTo: bottomAnchor),
            subview.rightAnchor.constraint(equalTo: rightAnchor),
        ])
    }

    override public var contentMode: UIViewContentMode {
        didSet {
            metalView.contentMode = contentMode
            switch contentMode {
            case .scaleToFill:
                displayView.displayLayer.videoGravity = .resize
            case .scaleAspectFit, .center:
                displayView.displayLayer.videoGravity = .resizeAspect
            case .scaleAspectFill:
                displayView.displayLayer.videoGravity = .resizeAspectFill
            default:
                break
            }
        }
    }

    #if canImport(UIKit)
    override public func touchesMoved(_ touches: Set<UITouch>, with: UIEvent?) {
        if options.display == .plane {
            super.touchesMoved(touches, with: with)
        } else {
            options.display.touchesMoved(touch: touches.first!)
        }
    }
    #else
    override public func touchesMoved(with event: NSEvent) {
        if options.display == .plane {
            super.touchesMoved(with: event)
        } else {
            options.display.touchesMoved(touch: event.allTouches().first!)
        }
    }
    #endif

    public func flush() {
        clearSubtitles()
        pixelBuffer = nil
        doviProfile = nil
        inputDynamicRange = "sdr"
        outputDynamicRange = "sdr"
        if displayView.isHidden {
            metalView.clear()
        } else {
            displayView.displayLayer.flushAndRemoveImage()
        }
    }

    public func invalidate() {
        displayLink.invalidate()
        subtitleTimer?.invalidate()
        subtitleTimer = nil
        clearSubtitles()
    }

    func clearSubtitles() {
        subtitleLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        displayedSubtitleIDs = []
        subtitleBounds = .zero
    }

    private var displayedSubtitleIDs: [ObjectIdentifier] = []
    private var subtitleBounds = CGRect.zero
    private func updateImageSubtitles() {
        let parts = imageSubtitleProvider?().filter { $0.image != nil } ?? []
        let ids = parts.map(ObjectIdentifier.init)
        guard ids != displayedSubtitleIDs || subtitleBounds != bounds else { return }
        clearSubtitles()
        displayedSubtitleIDs = ids
        subtitleBounds = bounds
        guard let size = pixelBuffer?.size, size.width > 0, size.height > 0 else { return }
        let aspectSize = CGSize(width: size.width, height: size.height * (pixelBuffer?.aspectRatio.height ?? 1) / max(pixelBuffer?.aspectRatio.width ?? 1, 0.001))
        let rect: CGRect
        if contentMode == .scaleToFill {
            rect = bounds
        } else if contentMode == .scaleAspectFill {
            let scale = max(bounds.width / aspectSize.width, bounds.height / aspectSize.height)
            rect = CGRect(x: (bounds.width - aspectSize.width * scale) / 2,
                          y: (bounds.height - aspectSize.height * scale) / 2,
                          width: aspectSize.width * scale, height: aspectSize.height * scale)
        } else {
            rect = AVMakeRect(aspectRatio: aspectSize, insideRect: bounds)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        subtitleLayer.frame = bounds
        for part in parts {
            #if canImport(UIKit)
            let image = part.image?.cgImage
            #else
            let image = part.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            #endif
            guard let image else { continue }
            let layer = CALayer()
            layer.contents = image
            layer.frame = CGRect(x: rect.minX + part.origin.x * rect.width / size.width,
                                 y: rect.minY + part.origin.y * rect.height / size.height,
                                 width: CGFloat(image.width) * rect.width / size.width,
                                 height: CGFloat(image.height) * rect.height / size.height)
            subtitleLayer.addSublayer(layer)
        }
        CATransaction.commit()
    }

    public func readNextFrame() {
        draw(force: true)
    }

//    deinit {
//        print()
//    }
}

extension MetalPlayView {
    @objc private func renderFrame() {
        draw(force: false)
    }

    private func draw(force: Bool) {
        autoreleasepool {
            // Leave frames in the bounded decoder queue while the system
            // renderer is full, so backpressure reaches the reader as well.
            if pixelBuffer != nil, !requiresMetal, !displayView.prepareForEnqueue() {
                return
            }
            guard let frame = renderSource?.getVideoOutputRender(force: force) else {
                return
            }
            pixelBuffer = frame.corePixelBuffer
            guard let pixelBuffer else {
                return
            }
            isDovi = frame.isDovi || frame.doviProfile != nil
            doviProfile = frame.doviProfile
            let isPQ = pixelBuffer.transferFunction == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            let isHLG = pixelBuffer.transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG
            let customDovi = frame.doviMetadata != nil
            let inputHDR = isPQ || isHLG || customDovi
            let hdrOutput = inputHDR && options.destinationDynamicRange != .sdr && screenSupportsHDR
            let processColor = customDovi || (inputHDR && !hdrOutput)
            let previousBackend = requiresMetal
            requiresMetal = processColor || !options.isUseDisplayLayer() || pixelBuffer.cvPixelBuffer == nil
            if previousBackend != requiresMetal { displayLayerDelegate?.renderingBackendDidChange() }
            inputDynamicRange = frame.doviProfile != nil ? "dolbyVision" : (isPQ ? "hdr10" : (isHLG ? "hlg" : "sdr"))
            outputDynamicRange = hdrOutput ? (customDovi || isPQ ? "hdr10" : "hlg") : "sdr"
            actualRenderingBackend = requiresMetal ? "metal" : "sampleBuffer"
            fps = frame.fps
            let cmtime = frame.cmtime
            let par = pixelBuffer.size
            let sar = pixelBuffer.aspectRatio
            if let pixelBuffer = pixelBuffer.cvPixelBuffer, !requiresMetal {
                if displayView.isHidden {
                    displayView.isHidden = false
                    metalView.isHidden = true
                    metalView.clear()
                }
                if let dar = options.customizeDar(sar: sar, par: par) {
                    pixelBuffer.aspectRatio = CGSize(width: dar.width, height: dar.height * par.width / par.height)
                }
                checkFormatDescription(pixelBuffer: pixelBuffer)
                guard set(pixelBuffer: pixelBuffer, time: cmtime) else { return }
            } else {
                if !displayView.isHidden {
                    displayView.isHidden = true
                    metalView.isHidden = false
                    displayView.displayLayer.flushAndRemoveImage()
                }
                let size: CGSize
                if options.display == .plane {
                    if let dar = options.customizeDar(sar: sar, par: par) {
                        size = CGSize(width: par.width, height: par.width * dar.height / dar.width)
                    } else {
                        size = CGSize(width: par.width, height: par.height * sar.height / sar.width)
                    }
                } else {
                    size = KSOptions.sceneSize
                }
                checkFormatDescription(pixelBuffer: pixelBuffer)
                metalView.draw(frame: frame, pixelBuffer: pixelBuffer, display: options.display, size: size,
                               processColor: processColor, hdrOutput: hdrOutput)
            }
            renderSource?.setVideo(time: cmtime, position: frame.position)
        }
    }

    private var screenSupportsHDR: Bool {
        #if os(macOS)
        return (window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
        #elseif os(iOS) || os(tvOS)
        if #available(iOS 16.0, tvOS 16.0, *) {
            return (window?.screen ?? UIScreen.main).potentialEDRHeadroom > 1
        }
        return false
        #else
        return false
        #endif
    }

    private func checkFormatDescription(pixelBuffer: PixelBufferProtocol) {
        if formatDescription == nil || !pixelBuffer.matche(formatDescription: formatDescription!) {
            clearSubtitles()
            if formatDescription != nil {
                let hidden = displayView.isHidden
                displayView.removeFromSuperview()
                displayView = AVSampleBufferDisplayView()
                displayView.isHidden = hidden
                displayView.frame = frame
                addSubview(displayView)
            }
            formatDescription = pixelBuffer.formatDescription
        }
    }

    private func set(pixelBuffer: CVPixelBuffer, time: CMTime) -> Bool {
        guard let formatDescription else { return false }
        return displayView.enqueue(imageBuffer: pixelBuffer, formatDescription: formatDescription, time: time)
    }
}

class MetalView: UIView {
    private let render = MetalRender()
    #if canImport(UIKit)
    override public class var layerClass: AnyClass { CAMetalLayer.self }
    #endif
    var metalLayer: CAMetalLayer {
        // swiftlint:disable force_cast
        layer as! CAMetalLayer
        // swiftlint:enable force_cast
    }

    init() {
        super.init(frame: .zero)
        #if !canImport(UIKit)
        layer = CAMetalLayer()
        #endif
        metalLayer.device = MetalRender.device
        metalLayer.framebufferOnly = true
//        metalLayer.displaySyncEnabled = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func clear() {
        if let drawable = metalLayer.nextDrawable() {
            render.clear(drawable: drawable)
        }
    }

    func draw(frame: VideoVTBFrame, pixelBuffer: PixelBufferProtocol, display: DisplayEnum, size: CGSize,
              processColor: Bool, hdrOutput: Bool) {
        metalLayer.drawableSize = size
        metalLayer.pixelFormat = processColor ? (hdrOutput ? .bgr10a2Unorm : .bgra8Unorm) : KSOptions.colorPixelFormat(bitDepth: pixelBuffer.bitDepth)
        let colorspace: CGColorSpace?
        if processColor {
            colorspace = CGColorSpace(name: hdrOutput ? CGColorSpace.itur_2020_PQ : CGColorSpace.sRGB)
        } else { colorspace = pixelBuffer.colorspace }
        if colorspace != nil, metalLayer.colorspace != colorspace {
            metalLayer.colorspace = colorspace
            KSLog("[video] CAMetalLayer colorspace \(String(describing: colorspace))")
        }
        #if !os(tvOS)
        if #available(iOS 16, *) {
            metalLayer.wantsExtendedDynamicRangeContent = hdrOutput
            // SDR has already been mapped by BT.2390. HDR output remains PQ
            // and is mapped to the actual panel once by Core Animation.
            metalLayer.edrMetadata = hdrOutput ? frame.edrMetadata : nil
        }
        #endif
        guard let drawable = metalLayer.nextDrawable() else {
            KSLog("[video] CAMetalLayer not readyForMoreMediaData")
            return
        }
        render.draw(pixelBuffer: pixelBuffer, display: display, drawable: drawable,
                    colorFrame: processColor ? frame : nil, hdrOutput: hdrOutput)
    }
}

class AVSampleBufferDisplayView: UIView {
    #if canImport(UIKit)
    override public class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    #endif
    var displayLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable force_cast
        layer as! AVSampleBufferDisplayLayer
        // swiftlint:enable force_cast
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if !canImport(UIKit)
        layer = AVSampleBufferDisplayLayer()
        #endif
        var controlTimebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &controlTimebase)
        if let controlTimebase {
            displayLayer.controlTimebase = controlTimebase
            CMTimebaseSetTime(controlTimebase, time: .zero)
            CMTimebaseSetRate(controlTimebase, rate: 1.0)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func prepareForEnqueue() -> Bool {
        if #available(macOS 11.0, iOS 14, tvOS 14, *) {
            if displayLayer.requiresFlushToResumeDecoding {
                displayLayer.flush()
            }
        }
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        return displayLayer.isReadyForMoreMediaData
    }

    @discardableResult
    func enqueue(imageBuffer: CVPixelBuffer, formatDescription: CMVideoFormatDescription, time: CMTime) -> Bool {
        guard prepareForEnqueue() else { return false }
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        //        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescription: formatDescription, sampleTiming: [timing], sampleBufferOut: &sampleBuffer)
        if let sampleBuffer {
            if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary], let dic = attachmentsArray.first {
                dic[kCMSampleAttachmentKey_DisplayImmediately] = true
            }
            displayLayer.enqueue(sampleBuffer)
            return true
        }
        return false
    }
}

#if os(macOS)
import CoreVideo

class CADisplayLink {
    private let displayLink: CVDisplayLink
    private var runloop: RunLoop?
    private var mode = RunLoop.Mode.default
    public var preferredFramesPerSecond = 60
    @available(macOS 12.0, *)
    public var preferredFrameRateRange: CAFrameRateRange {
        get {
            CAFrameRateRange()
        }
        set {}
    }

    public var timestamp: TimeInterval {
        var timeStamp = CVTimeStamp()
        if CVDisplayLinkGetCurrentTime(displayLink, &timeStamp) == kCVReturnSuccess, (timeStamp.flags & CVTimeStampFlags.hostTimeValid.rawValue) != 0 {
            return TimeInterval(timeStamp.hostTime / NSEC_PER_SEC)
        }
        return 0
    }

    public var duration: TimeInterval {
        CVDisplayLinkGetActualOutputVideoRefreshPeriod(displayLink)
    }

    public var targetTimestamp: TimeInterval {
        duration + timestamp
    }

    public var isPaused: Bool {
        get {
            !CVDisplayLinkIsRunning(displayLink)
        }
        set {
            if newValue {
                CVDisplayLinkStop(displayLink)
            } else {
                CVDisplayLinkStart(displayLink)
            }
        }
    }

    public init(target: NSObject, selector: Selector) {
        var displayLink: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        self.displayLink = displayLink!
        CVDisplayLinkSetOutputHandler(self.displayLink) { [weak self] _, _, _, _, _ in
            guard let self else { return kCVReturnSuccess }
            self.runloop?.perform(selector, target: target, argument: self, order: 0, modes: [self.mode])
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(self.displayLink)
    }

    public init(block: @escaping (() -> Void)) {
        var displayLink: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        self.displayLink = displayLink!
        CVDisplayLinkSetOutputHandler(self.displayLink) { _, _, _, _, _ in
            block()
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(self.displayLink)
    }

    open func add(to runloop: RunLoop, forMode mode: RunLoop.Mode) {
        self.runloop = runloop
        self.mode = mode
    }

    public func invalidate() {
        isPaused = true
        runloop = nil
        CVDisplayLinkSetOutputHandler(displayLink) { _, _, _, _, _ in
            kCVReturnError
        }
    }
}
#endif
