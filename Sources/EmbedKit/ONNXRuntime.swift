import CORT
import Darwin
import Foundation

// These objects remain inside Embedder's lock and never cross actor boundaries.
final class ONNXRuntime {
    let api: UnsafePointer<OrtApi>
    let environment: OpaquePointer
    let allocator: UnsafeMutablePointer<OrtAllocator>
    private let library: UnsafeMutableRawPointer

    init(directory: URL) throws {
        let path = directory.appendingPathComponent(ModelManifest.current.dylibName).path
        // Verify the exact bytes we are about to load; never dlopen an unverified library.
        guard (try? FileDigest.sha256Hex(of: URL(fileURLWithPath: path))) == ModelManifest.current.runtime.dylibSHA256 else {
            throw EmbeddingError.runtime("ONNX Runtime library failed integrity check: \(path)")
        }
        guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw EmbeddingError.runtime("dlopen: \(dlerror().map { String(cString: $0) } ?? path)")
        }
        do {
            guard let symbol = dlsym(library, "OrtGetApiBase") else {
                throw EmbeddingError.runtime("Runtime does not export OrtGetApiBase")
            }
            typealias GetBase = @convention(c) () -> UnsafePointer<OrtApiBase>?
            let getBase = unsafeBitCast(symbol, to: GetBase.self)
            guard let base = getBase(), let api = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
                throw EmbeddingError.runtime("Unsupported ONNX Runtime C API version")
            }
            self.api = api
            var env: OpaquePointer?
            try Self.check(api.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "EmbedHelper", &env), api: api)
            guard let env else { throw EmbeddingError.runtime("No runtime environment") }
            var allocator: UnsafeMutablePointer<OrtAllocator>?
            do {
                try Self.check(api.pointee.DisableTelemetryEvents(env), api: api)
                try Self.check(api.pointee.GetAllocatorWithDefaultOptions(&allocator), api: api)
                guard let allocator else { throw EmbeddingError.runtime("No CPU allocator") }
                self.allocator = allocator
            } catch {
                api.pointee.ReleaseEnv(env)
                throw error
            }
            self.environment = env
            self.library = library
        } catch {
            dlclose(library)
            throw error
        }
    }

    deinit {
        api.pointee.ReleaseEnv(environment)
        dlclose(library)
    }

    static func check(_ status: OpaquePointer?, api: UnsafePointer<OrtApi>) throws {
        if let status {
            let message = api.pointee.GetErrorMessage(status).map { String(cString: $0) } ?? "ONNX Runtime error"
            api.pointee.ReleaseStatus(status)
            throw EmbeddingError.runtime(message)
        }
    }

    func check(_ status: OpaquePointer?) throws { try Self.check(status, api: api) }

    func tensor<T>(_ values: [T], shape: [Int64], type: ONNXTensorElementDataType) throws -> ONNXTensor {
        var value: OpaquePointer?
        try check(api.pointee.CreateTensorAsOrtValue(allocator, shape, shape.count, type, &value))
        guard let value else { throw EmbeddingError.runtime("No tensor") }
        let result = ONNXTensor(value: value, runtime: self)
        var data: UnsafeMutableRawPointer?
        try check(api.pointee.GetTensorMutableData(value, &data))
        if !values.isEmpty {
            guard let data else { throw EmbeddingError.runtime("No tensor storage") }
            values.withUnsafeBytes { source in data.copyMemory(from: source.baseAddress!, byteCount: source.count) }
        }
        return result
    }
}

final class ONNXTensor {
    let value: OpaquePointer
    let runtime: ONNXRuntime
    init(value: OpaquePointer, runtime: ONNXRuntime) { self.value = value; self.runtime = runtime }
    deinit { runtime.api.pointee.ReleaseValue(value) }

    func floats() throws -> [Float] {
        let api = runtime.api.pointee
        var info: OpaquePointer?
        try runtime.check(api.GetTensorTypeAndShape(value, &info))
        guard let info else { throw EmbeddingError.runtime("Missing tensor shape") }
        defer { api.ReleaseTensorTypeAndShapeInfo(info) }
        var type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
        try runtime.check(api.GetTensorElementType(info, &type))
        guard type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT else {
            throw EmbeddingError.runtime("Expected a float32 output tensor")
        }
        var count = 0
        try runtime.check(api.GetTensorShapeElementCount(info, &count))
        guard count >= 0 else { throw EmbeddingError.runtime("Invalid output shape") }
        var data: UnsafeMutableRawPointer?
        try runtime.check(api.GetTensorMutableData(value, &data))
        if count == 0 { return [] }
        guard let data else { throw EmbeddingError.runtime("Missing tensor data") }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
    }
}

final class ONNXSession {
    let runtime: ONNXRuntime
    private let session: OpaquePointer

    init(runtime: ONNXRuntime, model: URL) throws {
        self.runtime = runtime
        let api = runtime.api.pointee
        var options: OpaquePointer?
        try runtime.check(api.CreateSessionOptions(&options))
        guard let options else { throw EmbeddingError.runtime("No session options") }
        defer { api.ReleaseSessionOptions(options) }
        try runtime.check(api.SetIntraOpNumThreads(options, 4))
        try runtime.check(api.SetInterOpNumThreads(options, 1))
        try runtime.check(api.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))
        // Avoid spinning worker threads between requests.
        try runtime.check(api.AddSessionConfigEntry(options, "session.intra_op.allow_spinning", "0"))
        var session: OpaquePointer?
        try runtime.check(api.CreateSession(runtime.environment, model.path, options, &session))
        guard let session else { throw EmbeddingError.runtime("No ONNX session") }
        self.session = session
    }

    deinit { runtime.api.pointee.ReleaseSession(session) }

    func run(_ inputs: [(String, ONNXTensor)], output: String) throws -> ONNXTensor {
        let names = inputs.map { strdup($0.0)! }
        defer { names.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = names.map { UnsafePointer($0) }
        let tensors: [OpaquePointer?] = inputs.map { $0.1.value }
        var result: OpaquePointer?
        try output.withCString { name in
            var outputName: UnsafePointer<CChar>? = name
            try runtime.check(runtime.api.pointee.Run(session, nil, pointers, tensors,
                                                      inputs.count, &outputName, 1, &result))
        }
        guard let result else { throw EmbeddingError.runtime("No model output") }
        return ONNXTensor(value: result, runtime: runtime)
    }
}
