#if os(macOS)
import AVFoundation
import Testing

@testable import WhisprLib

@Suite("Audio chunk copy/convert")
struct AudioChunkTests {

    /// Helper: create a stereo 48kHz buffer with known samples
    func makeStereoBuffer(ch0: [Float], ch1: [Float], sampleRate: Double = 48000) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(ch0.count))!
        buf.frameLength = AVAudioFrameCount(ch0.count)
        buf.floatChannelData![0].update(from: ch0, count: ch0.count)
        buf.floatChannelData![1].update(from: ch1, count: ch1.count)
        return buf
    }

    /// Helper: create a mono buffer with known samples
    func makeMonoBuffer(samples: [Float], sampleRate: Double = 48000) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        buf.floatChannelData![0].update(from: samples, count: samples.count)
        return buf
    }

    // MARK: - copyBuffer tests

    @Test("copyBuffer preserves mono samples exactly")
    func copyMonoPreservesSamples() {
        let input: [Float] = [0.1, 0.2, 0.3, -0.5, 0.0]
        let buf = makeMonoBuffer(samples: input)
        let chunk = copyBuffer(buf)
        #expect(chunk != nil)
        #expect(chunk!.samples.count == 5)
        #expect(chunk!.sampleRate == 48000)
        for i in 0..<input.count {
            #expect(abs(chunk!.samples[i] - input[i]) < 1e-6)
        }
    }

    @Test("copyBuffer mixes stereo to mono by averaging channels")
    func copyStereoMixesToMono() {
        // ch0 = [1.0, 0.0], ch1 = [0.0, 1.0] → mono = [0.5, 0.5]
        let buf = makeStereoBuffer(ch0: [1.0, 0.0], ch1: [0.0, 1.0])
        let chunk = copyBuffer(buf)
        #expect(chunk != nil)
        #expect(chunk!.samples.count == 2)
        #expect(abs(chunk!.samples[0] - 0.5) < 1e-6)
        #expect(abs(chunk!.samples[1] - 0.5) < 1e-6)
    }

    @Test("copyBuffer preserves sample rate")
    func copyStereoPreservesRate() {
        let buf = makeStereoBuffer(ch0: [0.1], ch1: [0.1], sampleRate: 44100)
        let chunk = copyBuffer(buf)
        #expect(chunk!.sampleRate == 44100)
    }

    @Test("copyBuffer returns nil for empty buffer")
    func copyEmptyBufferIsNil() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 0)!
        buf.frameLength = 0
        let chunk = copyBuffer(buf)
        #expect(chunk == nil)
    }

    // MARK: - makeBuffer tests

    @Test("makeBuffer creates valid mono PCMBuffer from chunk")
    func makeBufferFromChunk() {
        let chunk = AudioChunk(samples: [0.1, 0.2, 0.3], sampleRate: 48000)
        let buf = makeBuffer(from: chunk)
        #expect(buf != nil)
        #expect(buf!.frameLength == 3)
        #expect(buf!.format.sampleRate == 48000)
        #expect(buf!.format.channelCount == 1)
        let data = buf!.floatChannelData![0]
        #expect(abs(data[0] - 0.1) < 1e-6)
        #expect(abs(data[1] - 0.2) < 1e-6)
        #expect(abs(data[2] - 0.3) < 1e-6)
    }

    @Test("makeBuffer preserves sample rate")
    func makeBufferRate() {
        let chunk = AudioChunk(samples: [0.0], sampleRate: 16000)
        let buf = makeBuffer(from: chunk)
        #expect(buf!.format.sampleRate == 16000)
    }

    // MARK: - Round-trip tests

    @Test("Stereo buffer round-trips through copy+make as mono")
    func stereoRoundTrip() {
        let ch0: [Float] = [0.5, -0.3, 0.8]
        let ch1: [Float] = [0.5, -0.3, 0.8]
        let stereo = makeStereoBuffer(ch0: ch0, ch1: ch1, sampleRate: 48000)

        let chunk = copyBuffer(stereo)!
        let mono = makeBuffer(from: chunk)!

        #expect(mono.format.channelCount == 1)
        #expect(mono.format.sampleRate == 48000)
        #expect(mono.frameLength == 3)
        // Both channels identical → mono average == same values
        let data = mono.floatChannelData![0]
        for i in 0..<3 {
            #expect(abs(data[i] - ch0[i]) < 1e-6)
        }
    }

    @Test("Mono buffer round-trips exactly through copy+make")
    func monoRoundTrip() {
        let input: [Float] = [0.1, -0.9, 0.5, 0.0, 0.7]
        let original = makeMonoBuffer(samples: input)

        let chunk = copyBuffer(original)!
        let restored = makeBuffer(from: chunk)!

        #expect(restored.format.channelCount == 1)
        #expect(restored.frameLength == AVAudioFrameCount(input.count))
        let data = restored.floatChannelData![0]
        for i in 0..<input.count {
            #expect(abs(data[i] - input[i]) < 1e-6)
        }
    }
}
#endif
