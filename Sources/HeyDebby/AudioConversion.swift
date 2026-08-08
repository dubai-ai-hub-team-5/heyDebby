import AVFoundation
import Foundation

enum AudioConversionError: LocalizedError {
    case invalidInputFormat
    case couldNotCreateConverter
    case couldNotAllocateOutputBuffer
    case conversionFailed(String)
    case outputDataUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "The microphone supplied an invalid audio format."
        case .couldNotCreateConverter:
            return "The microphone audio format could not be converted."
        case .couldNotAllocateOutputBuffer:
            return "A converted audio buffer could not be allocated."
        case .conversionFailed(let detail):
            return "Audio conversion failed: \(detail)"
        case .outputDataUnavailable:
            return "Audio conversion produced no readable data."
        }
    }
}

/// Stateful converter for AssemblyAI's required raw PCM stream: signed 16-bit,
/// little-endian, mono audio at 16 kHz.
final class PCM16AudioConverter {
    static let assemblyAISampleRate = 16_000.0

    let targetSampleRate: Double

    private let targetAudioFormat: AVAudioFormat
    private let conversionLock = NSLock()
    private var audioConverter: AVAudioConverter?
    private var currentInputAudioFormat: AVAudioFormat?

    init(targetSampleRate: Double = PCM16AudioConverter.assemblyAISampleRate) {
        precondition(targetSampleRate > 0, "The target sample rate must be positive.")

        guard let targetAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            preconditionFailure("PCM16 mono is a required AVFoundation audio format.")
        }

        self.targetSampleRate = targetSampleRate
        self.targetAudioFormat = targetAudioFormat
    }

    func convert(_ audioBuffer: AVAudioPCMBuffer) throws -> Data {
        conversionLock.lock()
        defer { conversionLock.unlock() }

        guard audioBuffer.frameLength > 0 else { return Data() }
        guard audioBuffer.format.sampleRate > 0,
              audioBuffer.format.channelCount > 0 else {
            throw AudioConversionError.invalidInputFormat
        }

        let audioConverter = try converter(for: audioBuffer.format)
        let sampleRateRatio = targetSampleRate / audioBuffer.format.sampleRate
        let estimatedOutputFrameCount = ceil(Double(audioBuffer.frameLength) * sampleRateRatio) + 64

        guard estimatedOutputFrameCount <= Double(AVAudioFrameCount.max),
              let outputAudioBuffer = AVAudioPCMBuffer(
                pcmFormat: targetAudioFormat,
                frameCapacity: AVAudioFrameCount(estimatedOutputFrameCount)
              ) else {
            throw AudioConversionError.couldNotAllocateOutputBuffer
        }

        var hasProvidedInputBuffer = false
        var conversionError: NSError?
        let conversionStatus = audioConverter.convert(
            to: outputAudioBuffer,
            error: &conversionError
        ) { _, inputStatus in
            if hasProvidedInputBuffer {
                inputStatus.pointee = .noDataNow
                return nil
            }

            hasProvidedInputBuffer = true
            inputStatus.pointee = .haveData
            return audioBuffer
        }

        if conversionStatus == .error {
            throw AudioConversionError.conversionFailed(
                conversionError?.localizedDescription ?? "unknown converter error"
            )
        }

        guard outputAudioBuffer.frameLength > 0 else { return Data() }
        guard let outputDataPointer = outputAudioBuffer.audioBufferList.pointee.mBuffers.mData else {
            throw AudioConversionError.outputDataUnavailable
        }

        let bytesPerFrame = Int(targetAudioFormat.streamDescription.pointee.mBytesPerFrame)
        let outputByteCount = Int(outputAudioBuffer.frameLength) * bytesPerFrame
        guard outputByteCount > 0 else { return Data() }

        return Data(bytes: outputDataPointer, count: outputByteCount)
    }

    /// Optional convenience for call sites that intentionally drop an unconvertible buffer.
    func convertToPCM16Data(from audioBuffer: AVAudioPCMBuffer) -> Data? {
        try? convert(audioBuffer)
    }

    func reset() {
        conversionLock.lock()
        audioConverter = nil
        currentInputAudioFormat = nil
        conversionLock.unlock()
    }

    private func converter(for inputAudioFormat: AVAudioFormat) throws -> AVAudioConverter {
        if let currentInputAudioFormat,
           currentInputAudioFormat.isEqual(inputAudioFormat),
           let audioConverter {
            return audioConverter
        }

        guard let newAudioConverter = AVAudioConverter(
            from: inputAudioFormat,
            to: targetAudioFormat
        ) else {
            throw AudioConversionError.couldNotCreateConverter
        }

        // AVAudioConverter's default channel mapping is implementation-dependent for
        // multichannel input. Explicit downmixing guarantees the websocket receives mono.
        newAudioConverter.downmix = true
        currentInputAudioFormat = inputAudioFormat
        audioConverter = newAudioConverter
        return newAudioConverter
    }
}

typealias PCM16Mono16kHzAudioConverter = PCM16AudioConverter
