#if canImport(UIKit) && !os(tvOS) && !os(xrOS)
import UIKit

final class KSPlayerPreviewView: UIView {
    private let imageView = UIImageView()
    private let timeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 6
        layer.masksToBounds = true
        backgroundColor = UIColor.black.withAlphaComponent(0.85)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        timeLabel.textColor = .white
        timeLabel.textAlignment = .center
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        addSubview(imageView)
        addSubview(timeLabel)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = CGRect(x: 4, y: 4, width: bounds.width - 8, height: bounds.height - 27)
        timeLabel.frame = CGRect(x: 4, y: bounds.height - 23, width: bounds.width - 8, height: 19)
    }

    func update(image: CGImage?, time: TimeInterval) {
        imageView.image = image.map(UIImage.init(cgImage:))
        timeLabel.text = time.toString(for: .minOrHour)
        isHidden = image == nil
    }
}
#elseif os(macOS)
import AppKit

final class KSPlayerPreviewView: NSView {
    private let imageView = NSImageView()
    private let timeLabel = UILabel(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        timeLabel.alignment = .center
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        addSubview(imageView)
        addSubview(timeLabel)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        imageView.frame = NSRect(x: 4, y: 27, width: bounds.width - 8, height: bounds.height - 31)
        timeLabel.frame = NSRect(x: 4, y: 4, width: bounds.width - 8, height: 19)
    }

    func update(image: CGImage?, time: TimeInterval) {
        imageView.image = image.map { NSImage(cgImage: $0, size: NSSize(width: CGFloat($0.width), height: CGFloat($0.height))) }
        timeLabel.stringValue = time.toString(for: .minOrHour)
        isHidden = image == nil
    }
}
#endif
