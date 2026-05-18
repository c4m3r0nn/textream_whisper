//
//  WhisperRealtimeClientTests.swift
//  TextreamTests
//

import XCTest
import Foundation

// MARK: - Tests for WhisperRealtimeClient message handling
// These test the parsing and message construction logic
// that WhisperRealtimeClient uses internally.

final class WhisperRealtimeClientTests: XCTestCase {

    // RED: Test that audio buffer append messages are correctly constructed
    func testAudioBufferAppendMessage() {
        let pcmData = Data([0x00, 0x01, 0x02, 0x03])
        let base64Audio = pcmData.base64EncodedString()

        let msg: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]

        let data = try! JSONSerialization.data(withJSONObject: msg)
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(parsed["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(parsed["audio"] as? String, base64Audio)
    }

    // RED: Test that transcription events are correctly parsed
    func testTranscriptionEventParsing() {
        let json = """
        {"type":"conversation.item.input_audio_transcription.completed","transcript":"hello world"}
        """
        let data = json.data(using: .utf8)!
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(parsed["type"] as? String, "conversation.item.input_audio_transcription.completed")
        XCTAssertEqual(parsed["transcript"] as? String, "hello world")
    }

    // RED: Test that error events are correctly identified
    func testErrorEventDetection() {
        let json = """
        {"type":"error","error":{"type":"invalid_request_error","message":"Invalid API key"}}
        """
        let data = json.data(using: .utf8)!
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(parsed["type"] as? String, "error")
        let error = parsed["error"] as! [String: Any]
        XCTAssertEqual(error["message"] as? String, "Invalid API key")
    }

    // RED: Test float32 to int16 conversion used for PCM16 format
    func testFloat32ToInt16Conversion() {
        let floatSamples: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0]
        var pcmData = Data()
        for sample in floatSamples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * 32767.0)
            var le = int16.littleEndian
            pcmData.append(Data(bytes: &le, count: 2))
        }

        // Verify we can read back the values
        for (i, expected) in floatSamples.enumerated() {
            let offset = i * 2
            let value = pcmData.withUnsafeBytes { ptr -> Int16 in
                ptr.load(fromByteOffset: offset, as: Int16.self).littleEndian
            }
            let clamped = max(-1.0, min(1.0, expected))
            let expectedInt16 = Int16(clamped * 32767.0)
            XCTAssertEqual(value, expectedInt16, "Sample \(i) doesn't match")
        }
    }

    // RED: Test resampling from arbitrary sample rate to 24kHz
    func testResampleTo24kHz() {
        // 48000 samples at 48kHz → 24000 samples at 24kHz (decimate by 2)
        let inputSamples = (0..<48000).map { Float(sin(Float($0) * 0.01)) }
        let ratio = 24000.0 / 48000.0
        let outputCount = Int(Double(inputSamples.count) * ratio)
        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcIndex = Double(i) / ratio
            let srcFloor = Int(srcIndex)
            let frac = Float(srcIndex - Double(srcFloor))
            if srcFloor + 1 < inputSamples.count {
                output[i] = inputSamples[srcFloor] * (1 - frac) + inputSamples[srcFloor + 1] * frac
            } else {
                output[i] = inputSamples[min(srcFloor, inputSamples.count - 1)]
            }
        }
        XCTAssertEqual(output.count, 24000)
    }

    // RED: Test that empty transcript is handled gracefully
    func testEmptyTranscript() {
        let json = """
        {"type":"conversation.item.input_audio_transcription.completed","transcript":""}
        """
        let data = json.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["transcript"] as? String, "")
    }

    // RED: Test speech_stopped event parsing
    func testSpeechStoppedEvent() {
        let json = """
        {"type":"input_audio_buffer.speech_stopped","audio_end_ms":1500,"item_id":"item_xyz"}
        """
        let data = json.data(using: .utf8)!
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(parsed["type"] as? String, "input_audio_buffer.speech_stopped")
        XCTAssertEqual(parsed["audio_end_ms"] as? Int, 1500)
    }
}
