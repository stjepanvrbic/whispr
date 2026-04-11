#if os(macOS)
import AVFoundation
import Foundation

/// A deep-copied, mono PCM chunk that can safely cross isolation boundaries.
///
/// `AVAudioPCMBuffer` wraps non-Sendable native memory from the audio
/// engine — we copy the samples out so the chunk can flow through
/// `AsyncStream` into the Nemotron processing task.
struct AudioChunk: Sendable {
    let samples: [Float]    // mono, at the capture device's original sample rate
    let sampleRate: Double
}

/// Deep-copy a hardware buffer into a Sendable mono chunk.
/// Multi-channel input is mixed to mono by averaging channels (matches
/// FluidAudio's internal AudioConverter behaviour).
func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AudioChunk? {
    guard let channels = buffer.floatChannelData else { return nil }
    let frames = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard frames > 0 else { return nil }

    if channelCount == 1 {
        let samples = Array(UnsafeBufferPointer(start: channels[0], count: frames))
        return AudioChunk(samples: samples, sampleRate: buffer.format.sampleRate)
    }

    var mono = [Float](repeating: 0, count: frames)
    for ch in 0..<channelCount {
        let ptr = channels[ch]
        for i in 0..<frames { mono[i] += ptr[i] }
    }
    let scale = 1.0 / Float(channelCount)
    for i in 0..<frames { mono[i] *= scale }
    return AudioChunk(samples: mono, sampleRate: buffer.format.sampleRate)
}

/// Build a mono AVAudioPCMBuffer from an `AudioChunk`.
func makeBuffer(from chunk: AudioChunk) -> AVAudioPCMBuffer? {
    guard let fmt = AVAudioFormat(standardFormatWithSampleRate: chunk.sampleRate, channels: 1)
    else { return nil }
    let count = AVAudioFrameCount(chunk.samples.count)
    guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: count) else { return nil }
    pcm.frameLength = count
    pcm.floatChannelData![0].update(from: chunk.samples, count: chunk.samples.count)
    return pcm
}

/// Build a silent 16 kHz mono buffer of the given frame count.
///
/// Used to (a) warm up CoreML shader compilation at startup and
/// (b) append trailing silence on key-release so the decoder has enough
/// context to finish decoding any speech sitting in a partial chunk.
func silentBuffer(frames: Int) -> AVAudioPCMBuffer? {
    guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)
    else { return nil }
    guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))
    else { return nil }
    pcm.frameLength = AVAudioFrameCount(frames)
    // Buffer is already zeroed on init.
    return pcm
}
#endif
