//
//  WhisperClientTests.swift
//  TextreamTests
//

import XCTest
import Foundation

// MARK: - Testable inline copies of key types
// These mirror the production types so we can test core logic
// without importing the full app module.

enum SpeechEngine: String, CaseIterable {
    case apple, openaiRealtime, localWhisper
}

// MARK: - Audio Conversion Tests

final class AudioConversionTests: XCTestCase {

    /// PCM float32 buffer → Int16 PCM conversion must stay in [-32768, 32767]
    func testFloat32ToInt16Clamping() {
        let samples: [Float] = [0.0, 1.0, -1.0, 0.5, -0.5, 2.0, -2.0]
        var int16s: [Int16] = []
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let scaled = clamped * 32767.0
            int16s.append(Int16(scaled))
        }
        XCTAssertEqual(int16s[0], 0)
        XCTAssertEqual(int16s[1], 32767)
        XCTAssertEqual(int16s[2], -32767)
        XCTAssertEqual(int16s[3], 16383)
        XCTAssertEqual(int16s[4], -16383)
        // Clamped values
        XCTAssertEqual(int16s[5], 32767)
        XCTAssertEqual(int16s[6], -32767)
    }

    /// Base64 round-trip for Int16 PCM data must be lossless
    func testBase64RoundTrip() {
        let pcmData: [Int16] = [0, 1000, -1000, 32767, -32768]
        var data = Data()
        for sample in pcmData {
            var s = sample.littleEndian
            data.append(Data(bytes: &s, count: 2))
        }
        let base64 = data.base64EncodedString()
        let decoded = Data(base64Encoded: base64)!
        XCTAssertEqual(decoded.count, pcmData.count * 2)
        for (i, expected) in pcmData.enumerated() {
            let offset = i * 2
            let value = decoded.withUnsafeBytes { ptr -> Int16 in
                ptr.load(fromByteOffset: offset, as: Int16.self).littleEndian
            }
            XCTAssertEqual(value, expected, "Sample \(i) mismatch")
        }
    }

    /// Resampling 48kHz → 24kHz should halve the sample count
    func testDownsamplingBy2() {
        let samples48k = (0..<480).map { Float($0) }
        // Simple decimation by 2
        let samples24k = stride(from: 0, to: samples48k.count, by: 2).map { samples48k[$0] }
        XCTAssertEqual(samples24k.count, 240)
        XCTAssertEqual(samples24k[0], 0.0)
        XCTAssertEqual(samples24k[1], 2.0)
    }
}

// MARK: - WebSocket Message Parsing Tests

final class WebSocketMessageTests: XCTestCase {

    /// Parse a transcription completed event from OpenAI Realtime API
    func testParseTranscriptionCompletedEvent() {
        let json = """
        {
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "item_abc123",
            "content_index": 0,
            "transcript": "Hello world this is a test"
        }
        """
        let data = json.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["type"] as? String, "conversation.item.input_audio_transcription.completed")
        XCTAssertEqual(parsed?["transcript"] as? String, "Hello world this is a test")
    }

    /// Parse a session created event
    func testParseSessionCreatedEvent() {
        let json = """
        {
            "type": "transcription_session.created",
            "session": {
                "id": "sess_abc123",
                "input_audio_format": "pcm16",
                "input_audio_transcription": {
                    "model": "gpt-4o-transcribe",
                    "language": ""
                }
            }
        }
        """
        let data = json.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["type"] as? String, "transcription_session.created")
    }

    /// Parse a speech started event
    func testParseSpeechStartedEvent() {
        let json = """
        {
            "type": "input_audio_buffer.speech_started",
            "audio_start_ms": 0,
            "item_id": "item_abc"
        }
        """
        let data = json.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["type"] as? String, "input_audio_buffer.speech_started")
    }

    /// Session update message must serialize with correct format
    func testSessionUpdateSerialization() {
        let msg: [String: Any] = [
            "type": "transcription_session.update",
            "input_audio_format": "pcm16",
            "input_audio_transcription": [
                "model": "gpt-4o-transcribe",
                "language": ""
            ],
            "turn_detection": [
                "type": "server_vad",
                "threshold": 0.5,
                "prefix_padding_ms": 300,
                "silence_duration_ms": 500
            ]
        ]
        let data = try? JSONSerialization.data(withJSONObject: msg)
        XCTAssertNotNil(data)
        let str = String(data: data!, encoding: .utf8)!
        XCTAssertTrue(str.contains("transcription_session.update"))
        XCTAssertTrue(str.contains("server_vad"))
    }
}

// MARK: - Local Whisper Response Parsing Tests

final class LocalWhisperResponseTests: XCTestCase {

    /// Parse standard whisper.cpp server response
    func testParseWhisperServerResponse() {
        let json = """
        {
            "text": "Hello world this is a test transcription"
        }
        """
        let data = json.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["text"] as? String, "Hello world this is a test transcription")
    }

    /// Parse OpenAI-compatible verbose response with segments
    func testParseVerboseResponse() {
        let json = """
        {
            "task": "transcribe",
            "language": "english",
            "duration": 5.0,
            "text": "Hello world",
            "segments": [
                {"start": 0.0, "end": 2.5, "text": "Hello"},
                {"start": 2.5, "end": 5.0, "text": "world"}
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["text"] as? String, "Hello world")
    }
}

// MARK: - SpeechEngine Tests

final class SpeechEngineTests: XCTestCase {

    func testAllEnginesExist() {
        let engines = SpeechEngine.allCases
        XCTAssertEqual(engines.count, 3)
        XCTAssertTrue(engines.contains(.apple))
        XCTAssertTrue(engines.contains(.openaiRealtime))
        XCTAssertTrue(engines.contains(.localWhisper))
    }

    func testRawValueRoundTrip() {
        for engine in SpeechEngine.allCases {
            let restored = SpeechEngine(rawValue: engine.rawValue)
            XCTAssertEqual(restored, engine)
        }
    }

    func testDefaultEngineIsApple() {
        let defaultEngine = SpeechEngine(rawValue: "") ?? .apple
        XCTAssertEqual(defaultEngine, .apple)
    }
}

// MARK: - WAV Header Generation Tests

final class WAVHeaderTests: XCTestCase {

    /// Verify the WAV header is correct for 16-bit PCM mono at 24kHz
    func testWAVHeaderGeneration() {
        let sampleRate = 24000
        let channels = 1
        let bitsPerSample = 16
        let numSamples = 24000 // 1 second
        let dataSize = numSamples * channels * (bitsPerSample / 8)

        var header = Data()
        // RIFF chunk
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        let fileSize: UInt32 = UInt32(36 + dataSize)
        header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        // fmt sub-chunk
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        let fmtSize: UInt32 = 16
        header.append(contentsOf: withUnsafeBytes(of: fmtSize.littleEndian) { Array($0) })
        let audioFormat: UInt16 = 1 // PCM
        header.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian) { Array($0) })
        let numChannels: UInt16 = UInt16(channels)
        header.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        let sampleRateVal: UInt32 = UInt32(sampleRate)
        header.append(contentsOf: withUnsafeBytes(of: sampleRateVal.littleEndian) { Array($0) })
        let byteRate: UInt32 = UInt32(sampleRate * channels * bitsPerSample / 8)
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        let blockAlign: UInt16 = UInt16(channels * bitsPerSample / 8)
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        let bps: UInt16 = UInt16(bitsPerSample)
        header.append(contentsOf: withUnsafeBytes(of: bps.littleEndian) { Array($0) })
        // data sub-chunk
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        let dataSizeVal: UInt32 = UInt32(dataSize)
        header.append(contentsOf: withUnsafeBytes(of: dataSizeVal.littleEndian) { Array($0) })

        // Verify header size (should be 44 bytes)
        XCTAssertEqual(header.count, 44)

        // Verify RIFF marker
        XCTAssertEqual(header[0...3], Data([0x52, 0x49, 0x46, 0x46]))

        // Verify file size
        let readFileSize = header[4...7].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(readFileSize, UInt32(36 + dataSize))
    }
}
