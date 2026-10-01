import Metal

enum MetalShaderLibrary {
    static func load(device: MTLDevice, sourceName: String, requiredFunctions: [String]) -> MTLLibrary? {
        if let compiled = try? device.makeDefaultLibrary(bundle: Bundle.module),
           requiredFunctions.allSatisfy({ compiled.makeFunction(name: $0) != nil }) {
            return compiled
        }
        guard let url = Bundle.module.url(forResource: sourceName, withExtension: "metal"),
              let source = try? String(contentsOf: url),
              let runtime = try? device.makeLibrary(source: source, options: nil),
              requiredFunctions.allSatisfy({ runtime.makeFunction(name: $0) != nil })
        else { return nil }
        return runtime
    }
}
