import Accelerate

/// Turns a mono audio stream into a spectral-flux onset strength envelope.
///
/// Input is decimated to roughly 11 kHz, then analysed with a 1024-point STFT
/// at a hop of 128 samples (~86–94 envelope frames per second).
final class OnsetDetector {
    static let frameSize = 1024
    static let hopSize = 128
    private static let targetRate = 11_025.0
    /// Only bins below this contribute to the onset envelope, so the kick/snare
    /// backbeat drives the tempo rather than hi-hat subdivisions.
    private static let fluxCutoffHz = 2_500.0

    /// Envelope frames per second.
    let frameRate: Double
    /// Where in a frame's window an onset's flux peak lands, measured from the
    /// window start, in decimated samples. Calibrated by `BeatPhaseTests`.
    private static let onsetPosition = 880.0
    private let decimatedRate: Double
    private let fluxBins: Int

    private let decimation: Int
    private var decimationAccumulator: Float = 0
    private var decimationCount = 0

    private var frame: [Float]           // sliding analysis window (decimated samples)
    private var frameFill = 0
    private let window: [Float]
    private var windowed: [Float]
    private var evens: [Float]
    private var odds: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var magnitudes: [Float]
    private var previousLogMagnitudes: [Float]
    private var flux: [Float]
    private let dft: vDSP_DFT_Setup

    init(sampleRate: Double) {
        decimation = max(1, Int((sampleRate / Self.targetRate).rounded()))
        let decimatedRate = sampleRate / Double(decimation)
        self.decimatedRate = decimatedRate
        frameRate = decimatedRate / Double(Self.hopSize)
        let binHz = decimatedRate / Double(Self.frameSize)
        fluxBins = min(Self.frameSize / 2, Int(Self.fluxCutoffHz / binHz))

        let n = Self.frameSize
        let half = n / 2
        frame = [Float](repeating: 0, count: n)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        windowed = [Float](repeating: 0, count: n)
        evens = [Float](repeating: 0, count: half)
        odds = [Float](repeating: 0, count: half)
        real = [Float](repeating: 0, count: half)
        imag = [Float](repeating: 0, count: half)
        magnitudes = [Float](repeating: 0, count: half)
        previousLogMagnitudes = [Float](repeating: 0, count: half)
        flux = [Float](repeating: 0, count: half)
        dft = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
    }

    deinit {
        vDSP_DFT_DestroySetup(dft)
    }

    /// Feeds raw mono samples (at the original sample rate) and calls `onFrame`
    /// with each onset strength value produced.
    func process(_ samples: UnsafeBufferPointer<Float>, onFrame: (Float) -> Void) {
        let scale = 1 / Float(decimation)
        for sample in samples {
            // Boxcar average + decimate: crude low-pass, plenty for onset detection.
            decimationAccumulator += sample
            decimationCount += 1
            guard decimationCount == decimation else { continue }
            let decimated = decimationAccumulator * scale
            decimationAccumulator = 0
            decimationCount = 0

            frame[frameFill] = decimated
            frameFill += 1
            if frameFill == Self.frameSize {
                onFrame(analyzeFrame())
                // Slide the window forward by one hop.
                frame.withUnsafeMutableBufferPointer { buf in
                    let keep = Self.frameSize - Self.hopSize
                    buf.baseAddress!.update(from: buf.baseAddress! + Self.hopSize, count: keep)
                }
                frameFill = Self.frameSize - Self.hopSize
            }
        }
    }

    /// Stream time (seconds since the first sample) of the audio an onset in
    /// `frame` (0-based, possibly fractional) corresponds to.
    func time(ofFrame frame: Double) -> Double {
        (frame * Double(Self.hopSize) + Self.onsetPosition) / decimatedRate
    }

    private func analyzeFrame() -> Float {
        let half = Self.frameSize / 2
        vDSP.multiply(frame, window, result: &windowed)

        // zrop expects the real input split into even/odd samples.
        windowed.withUnsafeBufferPointer { src in
            src.withMemoryRebound(to: DSPComplex.self) { complexSrc in
                evens.withUnsafeMutableBufferPointer { re in
                    odds.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        vDSP_ctoz(complexSrc.baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                }
            }
        }
        vDSP_DFT_Execute(dft, evens, odds, &real, &imag)
        imag[0] = 0 // packed Nyquist term; ignore it

        // Log-compressed magnitude: log(1 + C·|X|).
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
        vDSP.multiply(100, magnitudes, result: &magnitudes)
        vDSP.add(1, magnitudes, result: &magnitudes)
        vForce.log(magnitudes, result: &magnitudes)

        // Half-wave rectified difference against the previous frame, summed.
        vDSP.subtract(magnitudes, previousLogMagnitudes, result: &flux)
        vDSP.clip(flux, to: 0...Float.greatestFiniteMagnitude, result: &flux)
        swap(&previousLogMagnitudes, &magnitudes)
        let sum = flux.withUnsafeBufferPointer { vDSP.sum(UnsafeBufferPointer(rebasing: $0[0..<fluxBins])) }
        return sum / Float(fluxBins)
    }
}
