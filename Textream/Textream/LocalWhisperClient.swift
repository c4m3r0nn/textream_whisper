//
//  LocalWhisperClient.swift
//  Textream
//
//  HTTP client for a local whisper.cpp server.
//  Sends WAV audio chunks to /v1/audio/transcriptions
//  and receives transcribed text in real-time.
//

import Foundation
import AVFoundation

@Observable
class LocalWhisperClient {
    var isServerReachable: Bool = false
    var error: String?
    var lastTranscript: String = ""

    /// Called on main thread with transcribed text
    var onTranscription: ((String) -> Void)?

    private var audioBuffer = Data()
    private let chunkSampleCount: Int = 24000 * 3  // 3 seconds at 24kHz
    private var isProcessing = false
    private var serverURL: String = "http://localhost:8099"

    // MARK: - Configuration

    func configure(serverURL: String) {
        self.serverURL = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
    }

    /// Check if the whisper.cpp server is running and reachable
    func checkServer() async throws -> Bool {
        guard let url = URL(string: "\(serverURL)/v1/models") else {
            throw LocalWhisperError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        let (_, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            DispatchQueue.main.async { [weak self] in
                self?.isServerReachable = true
            }
            return true
        }
        DispatchQueue.main.async { [weak self] in
            self?.isServerReachable = false
        }
        return false
    }

    // MARK: - Audio Processing

    /// Feed an audio buffer to be transcribed. Buffers are accumulated and sent in ~3s chunks.
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let pcmData = WhisperRealtimeClient.resampleTo24kHz(buffer)
        audioBuffer.append(pcmData)

        let chunkSize = chunkSampleCount * 2  // 2 bytes per Int16 sample
        if audioBuffer.count >= chunkSize {
            let chunk = audioBuffer.subdata(in: 0..<chunkSize)
            audioBuffer.removeFirst(chunkSize)
            sendChunkForTranscription(chunk)
        }
    }

    /// Reset the audio buffer
    func reset() {
        audioBuffer.removeAll()
    }

    /// Flush any remaining audio in the buffer
    func flush() {
        if !audioBuffer.isEmpty {
            sendChunkForTranscription(audioBuffer)
            audioBuffer.removeAll()
        }
    }

    // MARK: - HTTP Request

    private func sendChunkForTranscription(_ pcmData: Data) {
        guard !isProcessing else { return }
        isProcessing = true

        let wavData = Self.createWAV(pcmData: pcmData)
        let boundary = "Boundary-\(UUID().uuidString)"

        guard let url = URL(string: "\(serverURL)/v1/audio/transcriptions") else {
            isProcessing = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        // Build multipart body
        var body = Data()

        // file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)

        // model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)

        // response_format field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isProcessing = false
            }

            if let error {
                DispatchQueue.main.async {
                    self?.error = "Local Whisper request failed: \(error.localizedDescription)"
                    self?.isServerReachable = false
                }
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            if let errorMessage = json["error"] as? [String: Any],
               let message = errorMessage["message"] as? String {
                DispatchQueue.main.async {
                    self?.error = "Local Whisper error: \(message)"
                }
                return
            }

            if let text = json["text"] as? String, !text.isEmpty {
                DispatchQueue.main.async {
                    self?.lastTranscript = text
                    self?.onTranscription?(text)
                }
            }
        }.resume()
    }

    // MARK: - WAV Creation

    static func createWAV(pcmData: Data, sampleRate: Int = 24000, channels: Int = 1, bitsPerSample: Int = 16) -> Data {
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
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM format
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

    // MARK: - Errors

    enum LocalWhisperError: LocalizedError {
        case invalidURL
        case serverNotReachable
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid server URL"
            case .serverNotReachable: return "Whisper server not reachable. Make sure whisper-server is running."
            case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
            }
        }
    }
}
