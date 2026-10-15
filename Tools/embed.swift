import Foundation
import NaturalLanguage
let args = CommandLine.arguments
if args.count < 3 { fatalError("usage: embed.swift input.json output.json") }
guard let model = NLEmbedding.sentenceEmbedding(for: .english) else { fatalError("Apple English sentence embedding model unavailable") }
func vectorFor(_ item: [String: Any]) -> [Double]? {
    let title = item["title"] as! String
    let summary = item["summary"] as? String ?? ""
    if let vector = model.vector(for: title + ". " + summary) {
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        return vector.map { ($0 / max(magnitude, 1e-12) * 1_000_000).rounded() / 1_000_000 }
    }
    return nil
}
let modelName = "Apple NaturalLanguage English sentence embedding revision \(model.revision)"
if args.contains("--jsonl") {
    let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: args[1]))
    FileManager.default.createFile(atPath: args[2], contents: nil)
    let output = try FileHandle(forWritingTo: URL(fileURLWithPath: args[2]))
    func writeRecord(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(10)
        try output.write(contentsOf: data)
    }
    try writeRecord(["model": modelName, "dimensions": model.dimension])
    var buffer = Data()
    var count = 0
    func processLine(_ data: Data) throws {
        if data.isEmpty { return }
        let item = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard let vector = vectorFor(item) else { fatalError("Missing embedding for \(item["id"] ?? "unknown")") }
        try writeRecord(["id": item["id"]!, "embedding": vector])
        count += 1
        if count % 1000 == 0 { print("Embedded \(count) events (streaming)") }
    }
    while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 10) {
            try autoreleasepool { try processLine(Data(buffer[..<newline])) }
            buffer.removeSubrange(...newline)
        }
    }
    try processLine(buffer)
    try input.close()
    try output.close()
    print("Embedded \(count) events in \(model.dimension) dimensions, revision \(model.revision); streamed records")
} else {
    let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    let records = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    var vectors: [String: [Double]] = [:]
    for item in records { vectors[item["id"] as! String] = vectorFor(item) }
    let output: [String: Any] = ["model": modelName, "dimensions": model.dimension, "vectors": vectors]
    try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: URL(fileURLWithPath: args[2]))
    print("Embedded \(vectors.count) events in \(model.dimension) dimensions, revision \(model.revision)")
}
