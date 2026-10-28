import Foundation
import KSFFmpegBridge

/// One budget per media session; successful reconnects do not reset the limit.
struct PlaybackRecovery {
    enum Action: Equatable {
        case softwareDecode
        case reconnect(TimeInterval)
    }

    private var usedSoftwareDecode = false
    private var reconnects = 0

    mutating func next(error: NSError, streaming: Bool, hardware: Bool) -> Action? {
        guard error.domain == KSPlayerErrorDomain,
              let underlying = error.userInfo[NSUnderlyingErrorKey] as? AVError
        else { return nil }
        let networkErrors = [ETIMEDOUT, ECONNRESET, ECONNREFUSED, ECONNABORTED,
                             ENETDOWN, ENETUNREACH, EHOSTUNREACH, EPIPE, EIO]
        let isNetworkStage = [KSPlayerErrorCode.formatOpenInput.rawValue,
                              KSPlayerErrorCode.formatFindStreamInfo.rawValue,
                              KSPlayerErrorCode.readFrame.rawValue].contains(error.code)
        if streaming, isNetworkStage, networkErrors.contains(-underlying.code), reconnects < 3 {
            let delay = TimeInterval(1 << reconnects)
            reconnects += 1
            return .reconnect(delay)
        }
        let isVideoStage = [KSPlayerErrorCode.codesContextOpen.rawValue,
                            KSPlayerErrorCode.codecVideoSendPacket.rawValue,
                            KSPlayerErrorCode.codecVideoReceiveFrame.rawValue].contains(error.code)
        // Corrupt packets and missing RPU are not hardware terminal failures.
        if hardware, isVideoStage, !usedSoftwareDecode,
           [Int32(swift_AVERROR_EXTERNAL), -12903, -12911, -12913].contains(underlying.code)
        {
            usedSoftwareDecode = true
            return .softwareDecode
        }
        return nil
    }
}
