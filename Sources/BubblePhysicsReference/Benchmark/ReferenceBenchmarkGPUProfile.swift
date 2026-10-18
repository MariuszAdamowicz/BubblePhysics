/// Optional diagnostic instrumentation of a successfully published Metal frame.
/// Stage times partition completed command buffers, not individual kernels.
public struct ReferenceBenchmarkGPUFrameProfile: Sendable, Equatable {
    public static let stages = ["geometry", "newton", "pcg", "lineSearch", "ccd", "guards", "contours", "render"]
    public var commandBufferCount: Int
    public var encoderCount: Int
    public var stageGPUMilliseconds: [String: Double]
    public var hostEncodingMilliseconds: Double
    public var hostWaitingMilliseconds: Double
    public var hostReadbackMilliseconds: Double

    public init(commandBufferCount: Int, encoderCount: Int, stageGPUMilliseconds: [String: Double],
                hostEncodingMilliseconds: Double, hostWaitingMilliseconds: Double, hostReadbackMilliseconds: Double) {
        self.commandBufferCount = commandBufferCount
        self.encoderCount = encoderCount
        self.stageGPUMilliseconds = stageGPUMilliseconds
        self.hostEncodingMilliseconds = hostEncodingMilliseconds
        self.hostWaitingMilliseconds = hostWaitingMilliseconds
        self.hostReadbackMilliseconds = hostReadbackMilliseconds
    }
}
