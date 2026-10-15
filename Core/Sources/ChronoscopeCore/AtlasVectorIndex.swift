import Foundation

/// Deterministic sparse random-hyperplane locality-sensitive hashing.
/// Buckets select approximate candidates; cosine reranking supplies actual similarity scores.
public enum AtlasVectorIndex {
    public static let version = "sparse-xorshift32-v1-16x8x8"
    public static let tableCount = 16
    public static let bitsPerTable = 8
    public static let samplesPerHyperplane = 8

    public static func buckets(for vector: [Double]) -> [Int] {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else { return [] }
        var buckets: [Int] = []
        buckets.reserveCapacity(tableCount)
        for table in 0..<tableCount {
            var signature = 0
            for bit in 0..<bitsPerTable {
                var state = UInt32(0x9E3779B9) ^ (UInt32(table + 1) &* 0x85EBCA6B) ^ (UInt32(bit + 1) &* 0xC2B2AE35)
                var projection = 0.0
                for _ in 0..<samplesPerHyperplane {
                    state = xorshift32(state)
                    let dimension = Int(state) % vector.count
                    state = xorshift32(state)
                    projection += vector[dimension] * (state & 1 == 1 ? 1 : -1)
                }
                if projection >= 0 { signature |= 1 << bit }
            }
            buckets.append((table << bitsPerTable) | signature)
        }
        return buckets
    }

    private static func xorshift32(_ value: UInt32) -> UInt32 {
        var value = value
        value ^= value << 13
        value ^= value >> 17
        value ^= value << 5
        return value
    }
}
