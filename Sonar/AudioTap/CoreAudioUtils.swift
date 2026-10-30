import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        "\(operation) failed (\(fourCC(status)))"
    }

    private func fourCC(_ status: OSStatus) -> String {
        let n = UInt32(bitPattern: status)
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((n >> $0) & 0xFF))) }
        return chars.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " ") }
            ? "'\(String(chars))'" : "\(status)"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
}

extension AudioObjectPropertyAddress {
    static func global(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        scoped(selector, kAudioObjectPropertyScopeGlobal)
    }

    static func scoped(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    func read<T: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        default value: T
    ) throws -> T {
        var address = AudioObjectPropertyAddress.scoped(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &result), "Read property \(selector)")
        return result
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress.global(selector)
        var size = UInt32(MemoryLayout<CFString>.size)
        var result: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &result), "Read property \(selector)")
        guard let result else { throw CoreAudioError(status: kAudioHardwareUnspecifiedError, operation: "Read string \(selector)") }
        return result.takeRetainedValue() as String
    }

    static func defaultOutputDevice() throws -> AudioObjectID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID.unknown)
    }

    /// Seconds between audio being handed to this output device and it being heard:
    /// device + safety offset + first stream latency. Large for Bluetooth/AirPlay.
    func outputLatency() -> Double {
        let output = kAudioObjectPropertyScopeOutput
        guard let rate = try? read(kAudioDevicePropertyNominalSampleRate, default: Float64(0)), rate > 0 else { return 0 }
        var frames = (try? read(kAudioDevicePropertyLatency, scope: output, default: UInt32(0))) ?? 0
        frames += (try? read(kAudioDevicePropertySafetyOffset, scope: output, default: UInt32(0))) ?? 0

        var address = AudioObjectPropertyAddress.scoped(kAudioDevicePropertyStreams, output)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(self, &address, 0, nil, &size, &streams) == noErr {
                frames += (try? streams[0].read(kAudioStreamPropertyLatency, default: UInt32(0))) ?? 0
            }
        }
        return Double(frames) / rate
    }
}
