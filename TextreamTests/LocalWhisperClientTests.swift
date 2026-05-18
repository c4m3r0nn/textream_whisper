//
//  LocalWhisperClientTests.swift
//  TextreamTests
//

import XCTest
import Foundation

final class LocalWhisperClientTests: XCTestCase {

    // RED: Test WAV file construction from PCM16 data
    func testWAVFileConstruction() {
        let sampleRate = 24000
        let channels = 1
        let bitsPerSample = 16

        // Create 100ms of silence
        let numSamples = sampleRate / 10
        var pcmData = Data()
        for _ in 0..<numSamples {
            var zero: Int16 = 0
            pcmData.append(Data(bytes: &zero, count: 2))
        }

        let wavData = LocalWhisperTestHelper.createWAV(
            pcmData: pcmData,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )

        // WAV header should be 44 bytes
        XCTAssertEqual(wavData.count, 44 + pcmData.count)

        // Check RIFF marker
        XCTAssertEqual(wavData[0], 0x52) // R
        XCTAssertEqual(wavData[1], 0x49) // I
        XCTAssertEqual(wavData[2], 0x46) // F
        XCTAssertEqual(wavData[3], 0x46) // F

        // Check WAVE marker
        XCTAssertEqual(wavData[8], 0x57) // W
        XCTAssertEqual(wavData[9], 0x41) // A
        XCTAssertEqual(wavData[10], 0x56) // V
        XCTAssertEqual(wavData[11], 0x45) // E
    }

    // RED: Test that server URL is properly constructed
    func testServerURLConstruction() {
        let baseURL = "http://localhost:8099"
        let url = URL(string: "\(baseURL)/v1/audio/transcriptions")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.path, "/v1/audio/transcriptions")

        let secureURL = URL(string: "https://myserver.example.com:9000/v1/audio/transcriptions")
        XCTAssertNotNil(secureURL)
    }

    // RED: Test multipart form data boundary generation
    func testMultipartBoundary() {
        let boundary = "Boundary-\(UUID().uuidString)"
        XCTAssertTrue(boundary.hasPrefix("Boundary-"))
        XCTAssertTrue(boundary.count > 10)
    }

    // RED: Test transcription response parsing
    func testTranscriptionResponseParsing() {
        let json = """
        {"text":"Hello world this is a test"}
        """
        let data = json.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["text"] as? String, "Hello world this is a test")
    }

    // RED: Test error response parsing
    func testErrorResponseParsing() {
        let json = """
        {"error":{"message":"Model not found","type":"invalid_request_error"}}
        """
        let data = json.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed)
        let error = parsed?["error"] as? [String: Any]
        XCTAssertEqual(error?["message"] as? String, "Model not found")
    }

    // RED: Test that audio chunk timing is reasonable (3 second chunks at 24kHz)
    func testChunkTiming() {
        let sampleRate = 24000
        let chunkDurationSeconds = 3.0
        let chunkSamples = Int(Double(sampleRate) * chunkDurationSeconds)
        XCTAssertEqual(chunkSamples, 72000)
        let chunkBytes = chunkSamples * 2 // 16-bit = 2 bytes per sample
        XCTAssertEqual(chunkBytes, 144000)
    }
}

// Helper that mirrors the WAV creation logic in LocalWhisperClient
struct LocalWhisperTestHelper {
    static func createWAV(pcmData: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        var header = Data()
        let dataSize = pcmData.count
        let fileSize = 36 + dataSize

        // RIFF chunk
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        header.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        // fmt sub-chunk
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        header.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        let byteRate = UInt32(sampleRate * channels * bitsPerSample / 8)
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        let blockAlign = UInt16(channels * bitsPerSample / 8)
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })
        // data sub-chunk
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        header.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })

        return header + pcmData
    }
}
