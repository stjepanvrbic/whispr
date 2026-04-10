#if os(macOS)
import AVFoundation
import FluidAudio
import Foundation

/// Binary stdio transcription engine.
///
/// Protocol (all integers are little-endian):
///   stdin  → [uint32: sample_count][float32 × sample_count]
///            sample_count == 0 means "reset buffer" (new recording).
///   stdout ← one JSON line per request: {"text":"...","ms":123}
///   First stdout line is "READY" after model load.
///
/// The engine maintains an internal audio buffer.  Each request appends
/// new samples, then transcribes the full buffer — so the caller only
/// sends *new* audio each pass, not the entire recording.
@main
struct WhisprEngine {
    static func main() async {
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)

            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            var audioBuffer: [Float] = []
            let handle = FileHandle.standardInput

            fputs("READY\n", stdout)
            fflush(stdout)

            while true {
                // --- Read sample count (4 bytes, uint32 LE) ---
                let header = handle.readData(ofLength: 4)
                guard header.count == 4 else { break }
                let count = Int(header.withUnsafeBytes { $0.load(as: UInt32.self) })

                if count == 0 {
                    audioBuffer.removeAll(keepingCapacity: true)
                    fputs("{\"text\":\"\",\"ms\":0}\n", stdout)
                    fflush(stdout)
                    continue
                }

                // --- Read float32 samples ---
                let needed = count * MemoryLayout<Float>.size
                var raw = Data()
                raw.reserveCapacity(needed)
                while raw.count < needed {
                    let chunk = handle.readData(ofLength: needed - raw.count)
                    if chunk.isEmpty { break }
                    raw.append(chunk)
                }
                raw.withUnsafeBytes { ptr in
                    let floats = ptr.bindMemory(to: Float.self)
                    audioBuffer.append(contentsOf: floats)
                }

                // --- Build AVAudioPCMBuffer and transcribe ---
                let pcm = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(audioBuffer.count)
                )!
                pcm.frameLength = AVAudioFrameCount(audioBuffer.count)
                audioBuffer.withUnsafeBufferPointer { src in
                    memcpy(pcm.floatChannelData![0], src.baseAddress!,
                           src.count * MemoryLayout<Float>.stride)
                }

                let t0 = CFAbsoluteTimeGetCurrent()
                let result = try await manager.transcribe(pcm, source: .system)
                let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)

                fputs(encode(EngineResponse(text: result.text, ms: ms)) + "\n", stdout)
                fflush(stdout)
            }
        } catch {
            fputs("ERROR: \(error)\n", stderr)
            exit(1)
        }
    }
}

struct EngineResponse: Codable { let text: String; let ms: Int }

func encode(_ r: EngineResponse) -> String {
    String(data: try! JSONEncoder().encode(r), encoding: .utf8)!
}
#else
#error("whispr-engine requires macOS 14+")
#endif
