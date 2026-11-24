import Foundation

struct TimingWindow {
    struct Summary: Encodable {
        let p50: Double
        let p95: Double
        let samples: Int
    }

    private struct Sample {
        let milliseconds: Double
        let uptime: UInt64
    }

    private static let capacity = 240
    private static let maxAge: UInt64 = 4_000_000_000
    private var samples: [Sample] = []
    private var next = 0

    mutating func record(_ milliseconds: Double, at uptime: UInt64) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        let sample = Sample(milliseconds: milliseconds, uptime: uptime)
        if samples.count < Self.capacity {
            samples.append(sample)
        } else {
            samples[next] = sample
        }
        next = (next + 1) % Self.capacity
    }

    func summarize(at uptime: UInt64) -> Summary? {
        let recent = samples.filter { $0.uptime <= uptime && uptime - $0.uptime <= Self.maxAge }
            .map(\.milliseconds).sorted()
        guard !recent.isEmpty else { return nil }
        return Summary(
            p50: recent[(recent.count - 1) / 2],
            p95: recent[Int(ceil(Double(recent.count) * 0.95)) - 1],
            samples: recent.count
        )
    }

    static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000
    }
}
