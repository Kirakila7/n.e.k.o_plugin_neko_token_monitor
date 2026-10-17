import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import ImageIO
import AVFoundation
import QuartzCore

// This process has no network client and never attaches a screen-frame output.
// Only short PCM blocks are passed to the local tempo estimator.
final class AudioListener: NSObject, SCStreamOutput, SCStreamDelegate {
    @MainActor private var stream: SCStream?
    @MainActor private var generation: UInt64 = 0
    private let callbackLock = NSLock()
    private weak var acceptedStream: SCStream?
    private let queue = DispatchQueue(label: "neko.rhythm.audio", qos: .userInitiated)
    var onSamples: (([Float], Double, Double) -> Void)?
    var onError: ((String) -> Void)?

    private func acceptSamples(from stream: SCStream?) {
        callbackLock.lock(); acceptedStream = stream; callbackLock.unlock()
    }

    @MainActor func start() async throws -> Bool {
        generation &+= 1
        let request = generation
        let previous = stream; stream = nil; acceptSamples(from: nil)
        try? await previous?.stopCapture()
        guard generation == request, !Task.isCancelled else { return false }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard generation == request, !Task.isCancelled else { return false }
        guard let display = content.displays.first else {
            throw NSError(domain: "NekoRhythm", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可用的显示设备"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 64; config.height = 64
        config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        config.queueDepth = 2
        config.capturesAudio = true
        config.sampleRate = 22050
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // Publish before awaiting capture, so a concurrent stop can find it.
        stream = newStream
        acceptSamples(from: newStream)
        do {
            try await newStream.startCapture()
        } catch {
            if stream === newStream { stream = nil; acceptSamples(from: nil) }
            try? await newStream.stopCapture()
            guard generation == request, !Task.isCancelled else { return false }
            throw error
        }
        guard generation == request, !Task.isCancelled, stream === newStream else {
            // stopCapture can race an in-flight startCapture. Stop once more
            // after it completes to ensure an invalidated stream stays closed.
            if stream === newStream { stream = nil; acceptSamples(from: nil) }
            try? await newStream.stopCapture()
            return false
        }
        return true
    }

    @MainActor func stop() async {
        generation &+= 1
        let old = stream; stream = nil
        acceptSamples(from: nil)
        try? await old?.stopCapture()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            self.generation &+= 1
            self.stream = nil; self.acceptSamples(from: nil)
            self.onError?(error.localizedDescription)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        callbackLock.lock(); let accepted = acceptedStream === stream; callbackLock.unlock()
        guard accepted else { return }
        guard outputType == .audio, CMSampleBufferDataIsReady(buffer),
              let desc = CMSampleBufferGetFormatDescription(buffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        let fmt = basic.pointee
        guard fmt.mFormatID == kAudioFormatLinearPCM, fmt.mSampleRate > 0 else { return }
        var size = 0
        var block: CMBlockBuffer?
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buffer, bufferListSizeNeededOut: &size,
            bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &block)
        guard size >= MemoryLayout<AudioBufferList>.size else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buffer, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &block)
        guard status == noErr else { return }
        let channels = UnsafeMutableAudioBufferListPointer(list)
        let n = CMSampleBufferGetNumSamples(buffer)
        guard n > 0, n < 65536 else { return }
        var mono = [Float](repeating: 0, count: n)
        var channelCount: Float = 0
        for audio in channels {
            guard let bytes = audio.mData else { continue }
            let stride = max(1, Int(audio.mNumberChannels))
            if fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0 && fmt.mBitsPerChannel == 32 {
                let values = bytes.assumingMemoryBound(to: Float.self)
                let frames = min(n, Int(audio.mDataByteSize) / (4 * stride))
                for i in 0..<frames {
                    for c in 0..<stride { mono[i] += values[i * stride + c] }
                }
                channelCount += Float(stride)
            } else if fmt.mBitsPerChannel == 16 {
                let values = bytes.assumingMemoryBound(to: Int16.self)
                let frames = min(n, Int(audio.mDataByteSize) / (2 * stride))
                for i in 0..<frames {
                    for c in 0..<stride { mono[i] += Float(values[i * stride + c]) / 32768 }
                }
                channelCount += Float(stride)
            }
        }
        guard channelCount > 0 else { return }
        if channelCount != 1 { for i in mono.indices { mono[i] /= channelCount } }
        callbackLock.lock(); let stillAccepted = acceptedStream === stream; callbackLock.unlock()
        guard stillAccepted else { return }
        onSamples?(mono, fmt.mSampleRate, CACurrentMediaTime() - Double(n) / fmt.mSampleRate)
    }
}
