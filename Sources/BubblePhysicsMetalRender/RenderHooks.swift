import Metal
import simd

/// Punkty zaczepienia rysowania gry w tym samym passie co świat: gra rysuje własne elementy (tło sceny, interfejs w świecie,
/// nakładki) między tłem, warstwami i na końcu. Hak dostaje aktywny encoder i macierz świat → clip kamery renderu.
public struct RenderHooks {
    public typealias Hook = (MTLRenderCommandEncoder, simd_float4x4) throws -> Void

    /// Po tle, pod warstwą o najniższym numerze.
    public var afterBackground: Hook?
    /// Po warstwie o danym numerze (także gdy warstwa nie ma żadnego obiektu), pod następną.
    public var afterLayer: [Int32: Hook]
    /// Po wszystkich warstwach.
    public var overlay: Hook?

    public init(afterBackground: Hook? = nil, afterLayer: [Int32: Hook] = [:], overlay: Hook? = nil) {
        self.afterBackground = afterBackground
        self.afterLayer = afterLayer
        self.overlay = overlay
    }

    public static let none = RenderHooks()
}
