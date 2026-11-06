import Foundation
import Accelerate

public enum EmbeddingError: Error, Sendable, CustomStringConvertible {
    case invalid(String)
    case runtime(String)
    case database(String)
    case transport(String)

    public var description: String {
        switch self {
        case .invalid(let message), .runtime(let message), .database(let message), .transport(let message): message
        }
    }
}

func normalized(_ vector: [Float]) throws -> [Float] {
    guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else {
        throw EmbeddingError.invalid("Vector must be nonempty and finite")
    }
    let peak = vector.reduce(Float(0)) { max($0, abs($1)) }
    guard peak > 0 else { throw EmbeddingError.invalid("Zero vector") }
    let scaled = vector.map { $0 / peak }
    var norm: Float = 0
    vDSP_svesq(scaled, 1, &norm, vDSP_Length(scaled.count))
    var scale = 1 / sqrt(norm)
    var result = [Float](repeating: 0, count: vector.count)
    vDSP_vsmul(scaled, 1, &scale, &result, 1, vDSP_Length(vector.count))
    return result
}

/// Portable little-endian Float16 representation used by both SQLite and IPC.
public enum Float16Vectors {
    public static func encode(_ vector: [Float]) throws -> Data {
        guard vector.allSatisfy({ $0.isFinite && Float16($0).isFinite }) else {
            throw EmbeddingError.invalid("Vector cannot be represented as finite Float16")
        }
        var data = Data(capacity: vector.count * 2)
        for value in vector {
            let bits = Float16(value).bitPattern
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return data
    }

    public static func decode(_ data: Data, dimensions: Int) throws -> [Float] {
        guard dimensions > 0, dimensions <= EmbedProtocol.maxDimensions, data.count == dimensions * 2 else {
            throw EmbeddingError.invalid("Invalid Float16 vector length")
        }
        let bytes = Array(data)
        let values = (0..<dimensions).map { i in
            Float(Float16(bitPattern: UInt16(bytes[2 * i]) | UInt16(bytes[2 * i + 1]) << 8))
        }
        guard values.allSatisfy(\.isFinite) else { throw EmbeddingError.invalid("Non-finite Float16 vector") }
        return values
    }
}
