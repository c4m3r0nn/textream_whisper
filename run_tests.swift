//
//  run_tests.swift
//  Standalone test runner (no XCTest dependency)
//

import Foundation

var testsPassed = 0
var testsFailed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        testsPassed += 1
    } else {
        testsFailed += 1
        print("FAIL [\(file):\(line)]: \(message)")
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) {
    if a == b {
        testsPassed += 1
    } else {
        testsFailed += 1
        print("FAIL [\(file):\(line)]: \(message) — expected \(b), got \(a)")
    }
}

// MARK: - Audio Conversion Tests

print("=== Audio Conversion Tests ===")

do {
    // testFloat32ToInt16Clamping
    let samples: [Float] = [0.0, 1.0, -1.0, 0.5, -0.5, 2.0, -2.0]
    var int16s: [Int16] = []
    for s in samples {
        let clamped = max(-1.0, min(1.0, s))
        let scaled = clamped * 32767.0
        int16s.append(Int16(scaled))
    }
    assertEqual(int16s[0], Int16(0), "zero sample")
    assertEqual(int16s[1], Int16(32767), "max sample")
    assertEqual(int16s[2], Int16(-32767), "min sample")
    assertEqual(int16s[3], Int16(16383), "half sample")
    assertEqual(int16s[4], Int16(-16383), "negative half sample")
    assertEqual(int16s[5], Int16(32767), "clamped overflow")
    assertEqual(int16s[6], Int16(-32767), "clamped underflow")
}

do {
    // testBase64RoundTrip
    let pcmData: [Int16] = [0, 1000, -1000, 32767, -32768]
    var data = Data()
    for sample in pcmData {
        var s = sample.littleEndian
        data.append(Data(bytes: &s, count: 2))
    }
    let base64 = data.base64EncodedString()
    let decoded = Data(base64Encoded: base64)!
    assertEqual(decoded.count, pcmData.count * 2, "base64 round-trip size")
    for (i, expected) in pcmData.enumerated() {
        let offset = i * 2
        let value = decoded.withUnsafeBytes { ptr -> Int16 in
            ptr.load(fromByteOffset: offset, as: Int16.self).littleEndian
        }
        assertEqual(value, expected, "base64 round-trip sample \(i)")
    }
}

do {
    // testDownsamplingBy2
    let samples48k = (0..<480).map { Float($0) }
    let samples24k = stride(from: 0, to: samples48k.count, by: 2).map { samples48k[$0] }
    assertEqual(samples24k.count, 240, "downsampled count")
    assertEqual(samples24k[0], 0.0, "first sample")
    assertEqual(samples24k[1], 2.0, "second sample")
}

// MARK: - WebSocket Message Parsing Tests

print("=== WebSocket Message Tests ===")

do {
    // testParseTranscriptionCompletedEvent
    let json = """
    {"type":"conversation.item.input_audio_transcription.completed","transcript":"Hello world this is a test"}
    """
    let data = json.data(using: .utf8)!
    let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    assert(parsed != nil, "transcription event parsed")
    assertEqual(parsed?["type"] as? String, "conversation.item.input_audio_transcription.completed", "type")
    assertEqual(parsed?["transcript"] as? String, "Hello world this is a test", "transcript")
}

do {
    // testParseSessionCreatedEvent
    let json = """
    {"type":"transcription_session.created","session":{"id":"sess_abc"}}
    """
    let data = json.data(using: .utf8)!
    let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    assert(parsed != nil, "session created parsed")
    assertEqual(parsed?["type"] as? String, "transcription_session.created", "type")
}

do {
    // testParseErrorEvent
    let json = """
    {"type":"error","error":{"type":"invalid_request_error","message":"Invalid API key"}}
    """
    let data = json.data(using: .utf8)!
    let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    assertEqual(parsed["type"] as? String, "error", "error type")
    let error = parsed["error"] as! [String: Any]
    assertEqual(error["message"] as? String, "Invalid API key", "error message")
}

do {
    // testSessionUpdateSerialization
    let msg: [String: Any] = [
        "type": "transcription_session.update",
        "input_audio_format": "pcm16",
        "turn_detection": ["type": "server_vad", "threshold": 0.5]
    ]
    let data = try! JSONSerialization.data(withJSONObject: msg)
    let str = String(data: data, encoding: .utf8)!
    assert(str.contains("transcription_session.update"), "contains type")
    assert(str.contains("server_vad"), "contains VAD type")
}

// MARK: - Local Whisper Response Tests

print("=== Local Whisper Response Tests ===")

do {
    // testParseWhisperServerResponse
    let json = """
    {"text":"Hello world this is a test transcription"}
    """
    let data = json.data(using: .utf8)!
    let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    assert(parsed != nil, "whisper response parsed")
    assertEqual(parsed?["text"] as? String, "Hello world this is a test transcription", "text")
}

do {
    // testErrorResponseParsing
    let json = """
    {"error":{"message":"Model not found","type":"invalid_request_error"}}
    """
    let data = json.data(using: .utf8)!
    let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let error = parsed?["error"] as? [String: Any]
    assertEqual(error?["message"] as? String, "Model not found", "error message")
}

// MARK: - SpeechEngine Tests

print("=== Speech Engine Tests ===")

enum SpeechEngine: String, CaseIterable {
    case apple, openaiRealtime, localWhisper
}

do {
    let engines = SpeechEngine.allCases
    assertEqual(engines.count, 3, "engine count")
    assert(engines.contains(.apple), "contains apple")
    assert(engines.contains(.openaiRealtime), "contains openaiRealtime")
    assert(engines.contains(.localWhisper), "contains localWhisper")

    for engine in engines {
        let restored = SpeechEngine(rawValue: engine.rawValue)
        assertEqual(restored, engine, "rawValue round-trip for \(engine)")
    }

    let defaultEngine = SpeechEngine(rawValue: "") ?? .apple
    assertEqual(defaultEngine, .apple, "default is apple")
}

// MARK: - WAV Header Tests

print("=== WAV Header Tests ===")

do {
    let sampleRate = 24000
    let numSamples = 24000
    let dataSize = numSamples * 2

    var header = Data()
    header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
    let fileSize: UInt32 = UInt32(36 + dataSize)
    header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
    header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
    header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
    header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
    header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
    header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // mono
    header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
    let byteRate = UInt32(sampleRate * 1 * 16 / 8)
    header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
    header.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) }) // block align
    header.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // bits
    header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
    header.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })

    assertEqual(header.count, 44, "WAV header is 44 bytes")
    assertEqual(header[0], 0x52, "RIFF R")
    assertEqual(header[1], 0x49, "RIFF I")
    assertEqual(header[2], 0x46, "RIFF F")
    assertEqual(header[3], 0x46, "RIFF F")
}

// MARK: - Chunk Timing Tests

print("=== Chunk Timing Tests ===")

do {
    let sampleRate = 24000
    let chunkDuration = 3.0
    let chunkSamples = Int(Double(sampleRate) * chunkDuration)
    assertEqual(chunkSamples, 72000, "3s at 24kHz = 72000 samples")
    let chunkBytes = chunkSamples * 2
    assertEqual(chunkBytes, 144000, "72000 Int16 samples = 144000 bytes")
}

// MARK: - Resampling Tests

print("=== Resampling Tests ===")

do {
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
    assertEqual(output.count, 24000, "resampled count")
}

// MARK: - Results

print("")
print("=== Results ===")
print("Passed: \(testsPassed)")
print("Failed: \(testsFailed)")
if testsFailed == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("SOME TESTS FAILED")
    exit(1)
}
