import Foundation
import AVFoundation
import Speech

/// On-device transcription of an audio file via the macOS 26 `SpeechAnalyzer` /
/// `SpeechTranscriber` long-form API.
///
/// Why this API (not `SFSpeechRecognizer`): the legacy recognizer treats a file
/// as short dictation and resets per speech segment, returning only the final
/// segment for long audio. `SpeechTranscriber` transcribes the whole file and
/// streams finalized, non-overlapping results — measured at ~54× realtime
/// on-device (a 51-min memo in <60s) during the feasibility spike.
///
/// Gated to macOS 26+ (`@available`); the platform floor is macOS 13, so callers
/// must check availability and degrade gracefully on older systems. No network
/// and no `Info.plist` usage string are required — it runs through the host
/// process's existing TCC context like the other integrations.
@available(macOS 26.0, *)
public enum VoiceMemosTranscriber {

    /// A time-stamped chunk of transcript, aligned to the audio.
    public struct Segment: Sendable {
        public let start: Double  // seconds
        public let end: Double    // seconds
        public let text: String
    }

    public struct Transcript: Sendable {
        public let text: String
        public let segments: [Segment]
        public var wordCount: Int {
            text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        }
    }

    public enum TranscribeError: Error, CustomStringConvertible {
        case localeUnavailable(String)
        case modelInstallFailed(String)
        case audioUnreadable(String)

        public var description: String {
            switch self {
            case .localeUnavailable(let l): return "no speech model available for locale '\(l)' (and none could be installed — offline?)"
            case .modelInstallFailed(let m): return "speech model install failed: \(m)"
            case .audioUnreadable(let m): return "could not read audio for transcription: \(m)"
            }
        }
    }

    /// True if long-form transcription is supported on this system.
    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// Transcribe the audio at `url` in `localeIdentifier` (BCP-47, e.g.
    /// "en-US"). Downloads the on-device model for the locale if needed. Throws
    /// `TranscribeError` on unrecoverable failure.
    public static func transcribe(url: URL, localeIdentifier: String) async throws -> Transcript {
        let requested = Locale(identifier: localeIdentifier)
        // Snap to a model-supported locale (e.g. "en" → "en-US").
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) ?? requested

        // Finalized results only (no volatile/partial), so results are
        // non-overlapping and safe to concatenate in order.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // Ensure the locale's on-device model is installed (one-time cost).
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscribeError.modelInstallFailed(error.localizedDescription)
        }

        // Confirm the locale really is usable now; otherwise fail clearly.
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        if !installed.contains(locale.identifier(.bcp47)) {
            throw TranscribeError.localeUnavailable(locale.identifier(.bcp47))
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw TranscribeError.audioUnreadable(error.localizedDescription)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Collect finalized results concurrently as the analyzer emits them.
        let collector = Task { () throws -> (String, [Segment]) in
            var full = ""
            var segments: [Segment] = []
            for try await result in transcriber.results {
                let chunk = String(result.text.characters)
                full += chunk
                segments.append(Segment(
                    start: result.range.start.seconds,
                    end: result.range.end.seconds,
                    text: chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
            return (full, segments)
        }

        _ = try await analyzer.analyzeSequence(from: audioFile)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let (text, segments) = try await collector.value
        return Transcript(text: text, segments: segments)
    }
}
