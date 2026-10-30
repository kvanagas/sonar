import AudioToolbox
import CoreAudio
import Foundation
import os

/// Captures the system audio mix (or chosen processes) through a Core Audio
/// process tap without muting or rerouting playback, and writes it as mono
/// floats into a ring buffer.
final class SystemAudioTap {
    /// Largest IO buffer we downmix in one go; bigger buffers are processed in chunks.
    private static let maxChunk = 4096

    let ring: RingBuffer
    private(set) var sampleRate: Double = 48_000
    /// Delay from the tap seeing audio to it coming out of the speakers.
    private(set) var outputLatency: Double = 0

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let mono = UnsafeMutablePointer<Float>.allocate(capacity: SystemAudioTap.maxChunk)
    private let log = Logger(subsystem: "com.karolisvanagas.sonar", category: "tap")

    var isRunning: Bool { ioProcID != nil }

    init(ring: RingBuffer) {
        self.ring = ring
    }

    deinit {
        stop()
        mono.deallocate()
    }

    /// Starts capturing. `processes` limits the tap to those Core Audio process
    /// objects; nil captures everything the system plays.
    func start(processes: [AudioObjectID]? = nil) throws {
        guard !isRunning else { return }
        do {
            try startTap(processes: processes)
        } catch {
            stop()
            throw error
        }
    }

    private func startTap(processes: [AudioObjectID]?) throws {
        let description = processes.map { CATapDescription(stereoMixdownOfProcesses: $0) }
            ?? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Sonar"
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var tap = AudioObjectID.unknown
        try check(AudioHardwareCreateProcessTap(description, &tap), "Create process tap")
        tapID = tap

        let format = try tapID.read(kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        sampleRate = format.mSampleRate
        log.info("Tap format: \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch")

        let outputDevice = try AudioObjectID.defaultOutputDevice()
        let outputUID = try outputDevice.readString(kAudioDevicePropertyDeviceUID)
        outputLatency = outputDevice.outputLatency()
        log.info("Output latency: \(self.outputLatency * 1000, format: .fixed(precision: 1)) ms")
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sonar Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var device = AudioObjectID.unknown
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "Create aggregate device")
        aggregateID = device

        let ring = self.ring
        let mono = self.mono
        let maxChunk = Self.maxChunk
        var procID: AudioDeviceIOProcID?
        // nil queue: the block runs directly on the real-time IO thread.
        // It must not allocate, lock or call into Swift concurrency.
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let firstData = first.mData else { return }

            if buffers.count == 1 {
                // Interleaved: one buffer with N channels.
                let channels = Int(max(1, first.mNumberChannels))
                let samples = firstData.assumingMemoryBound(to: Float.self)
                let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                let scale = 1 / Float(channels)
                var offset = 0
                while offset < frames {
                    let n = min(maxChunk, frames - offset)
                    for i in 0..<n {
                        var sum: Float = 0
                        let base = (offset + i) * channels
                        for c in 0..<channels { sum += samples[base + c] }
                        mono[i] = sum * scale
                    }
                    ring.write(mono, count: n)
                    offset += n
                }
            } else {
                // Non-interleaved: one mono buffer per channel.
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                let scale = 1 / Float(buffers.count)
                var offset = 0
                while offset < frames {
                    let n = min(maxChunk, frames - offset)
                    for i in 0..<n { mono[i] = 0 }
                    for buffer in buffers {
                        guard let data = buffer.mData else { continue }
                        let samples = data.assumingMemoryBound(to: Float.self) + offset
                        for i in 0..<n { mono[i] += samples[i] }
                    }
                    for i in 0..<n { mono[i] *= scale }
                    ring.write(mono, count: n)
                    offset += n
                }
            }
        }, "Create IO proc")
        ioProcID = procID

        try check(AudioDeviceStart(aggregateID, ioProcID), "Start aggregate device")
        log.info("Tap started")
    }

    /// Tears everything down in reverse order of creation. Safe to call repeatedly.
    func stop() {
        if aggregateID != .unknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = .unknown
        tapID = .unknown
    }
}
