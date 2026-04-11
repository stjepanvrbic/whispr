#if os(macOS)
import AVFoundation
import Foundation

final class AudioCapture: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    init() {}

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
        let engine = AVAudioEngine()
        self.engine = engine

        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        let bufferSize = AVAudioFrameCount(hwFormat.sampleRate * 0.56)

        input.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) {
            [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            log("Audio engine start failed: \(error)")
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        onBuffer = nil
    }
}
#endif
