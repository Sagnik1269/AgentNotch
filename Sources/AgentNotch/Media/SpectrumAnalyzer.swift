import Accelerate
import Foundation

/// Turns a stream of mono samples into a few smoothed, 0...1 frequency-band levels.
///
/// 1024-point FFT with a Hann window and 50% overlap, log-spaced bands, a gentle treble tilt,
/// and automatic gain (relative to a slowly decaying peak) so quiet and loud tracks both move.
/// Not thread-safe: use from one queue.
final class SpectrumAnalyzer {
    let bandCount: Int
    var sampleRate: Float = 48_000

    private let size = 1024
    private var half: Int { size / 2 }
    private let setup: vDSP_DFT_Setup
    private var window: [Float]
    private var pending: [Float] = []
    private var frame: [Float]
    private var inReal: [Float], inImag: [Float], outReal: [Float], outImag: [Float]
    private var smoothed: [Float]
    private var peakDB: Float = -40

    /// Band edges in Hz: bass, low-mids, high-mids, treble.
    private let edges: [Float] = [40, 250, 1_000, 4_000, 14_000]
    /// dB boost per band: music energy falls with frequency, so lift the highs to keep them visible.
    private let tilt: [Float] = [0, 4, 8, 13]
    /// How many dB below the running peak reads as zero.
    private let dynamicRange: Float = 34
    /// Below this RMS (~ -74 dBFS) the input counts as silence.
    private let silenceRMS: Float = 2e-4

    init(bandCount: Int = 4) {
        precondition(bandCount == 4, "band edges are defined for 4 bands")
        self.bandCount = bandCount
        setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        frame = [Float](repeating: 0, count: size)
        inReal = [Float](repeating: 0, count: size / 2)
        inImag = inReal; outReal = inReal; outImag = inReal
        smoothed = [Float](repeating: 0, count: bandCount)
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    func reset() {
        pending.removeAll(keepingCapacity: true)
        smoothed = [Float](repeating: 0, count: bandCount)
        peakDB = -40
    }

    /// Feeds samples; returns new levels if at least one FFT frame completed.
    func append(_ samples: UnsafeBufferPointer<Float>) -> [Float]? {
        pending.append(contentsOf: samples)
        var result: [Float]?
        while pending.count >= size {
            result = analyzeFrame()
            pending.removeFirst(half) // 50% overlap
        }
        return result
    }

    private func analyzeFrame() -> [Float] {
        var rms: Float = 0
        pending.withUnsafeBufferPointer { p in
            vDSP_rmsqv(p.baseAddress!, 1, &rms, vDSP_Length(size))
            vDSP_vmul(p.baseAddress!, 1, window, 1, &frame, 1, vDSP_Length(size))
        }

        var targets = [Float](repeating: 0, count: bandCount)
        if rms > silenceRMS {
            // Pack real input as even/odd split complex, as the real-to-complex DFT expects.
            frame.withUnsafeBufferPointer { fp in
                fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                    inReal.withUnsafeMutableBufferPointer { r in
                        inImag.withUnsafeMutableBufferPointer { i in
                            var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                }
            }
            vDSP_DFT_Execute(setup, inReal, inImag, &outReal, &outImag)

            let binHz = sampleRate / Float(size)
            var bandDB = [Float](repeating: -120, count: bandCount)
            for b in 0..<bandCount {
                let lo = max(1, Int(edges[b] / binHz))
                let hi = min(half, max(lo + 1, Int(edges[b + 1] / binHz)))
                var energy: Float = 0
                for k in lo..<hi { energy += outReal[k] * outReal[k] + outImag[k] * outImag[k] }
                energy /= Float(hi - lo)
                bandDB[b] = 10 * log10f(energy + 1e-12) + tilt[b]
            }

            // Automatic gain: jump up to new peaks instantly, decay ~4.5 dB/s at ~94 frames/s.
            peakDB = max(bandDB.max() ?? peakDB, peakDB - 0.05)
            let floor = peakDB - dynamicRange
            targets = bandDB.map { min(max(($0 - floor) / dynamicRange, 0), 1) }
        }

        // Fast attack, slower release, like a VU meter.
        for b in 0..<bandCount {
            let k: Float = targets[b] > smoothed[b] ? 0.55 : 0.16
            smoothed[b] += (targets[b] - smoothed[b]) * k
            if smoothed[b] < 0.005 { smoothed[b] = 0 }
        }
        return smoothed
    }
}
