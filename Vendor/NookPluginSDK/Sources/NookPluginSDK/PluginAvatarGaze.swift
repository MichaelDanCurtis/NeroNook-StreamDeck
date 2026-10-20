import Foundation

/// Decorative pointer direction only. Positive y looks up. No audio or agent state.
public struct PluginAvatarGaze: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double = 0, y: Double = 0) {
        self.x = x.isFinite ? min(1, max(-1, x)) : 0
        self.y = y.isFinite ? min(1, max(-1, y)) : 0
    }
    // Ease outward so nearby pointer motion is readable, without a dead zone
    // or an abrupt clamp. Match the offline web renderer's articulated pose.
    private var bodyX: Double { sin(x * .pi / 2) }
    private var bodyY: Double { sin(y * .pi / 2) }
    public var yawDegrees: Double { bodyX * 26 }
    public var pitchDegrees: Double { -bodyY * 16 }
    public var rollDegrees: Double { -bodyX * 4 }
    public var offsetX: Double { bodyX * 0.07 }
    public var offsetY: Double { bodyY * 0.045 }
    /// Both positions use the surface's top-left coordinate system.
    public static func towards(pointer: CGPoint, center: CGPoint, range: CGSize, enabled: Bool = true) -> Self {
        guard enabled, pointer.x.isFinite, pointer.y.isFinite, center.x.isFinite,
              center.y.isFinite, range.width.isFinite, range.height.isFinite,
              range.width > 0, range.height > 0 else { return .init() }
        return .init(x: (pointer.x-center.x)/range.width, y: (center.y-pointer.y)/range.height)
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Samples the public cursor position without an input monitor/event tap.
/// One bounded timer per mounted renderer; unchanged samples produce no work.
@MainActor final class PluginAvatarPointerSource {
    struct Sample: Equatable {
        let x: Double, y: Double, rangeX: Double, rangeY: Double
        var values: [String: Double] { ["x":x,"y":y,"rangeX":rangeX,"rangeY":rangeY] }
    }
    private weak var view: NSView?
    // All mutation is on MainActor; nonisolated deinit only invalidates it.
    nonisolated(unsafe) private var timer: Timer?
    private var receive: ((Sample?) -> Void)?
    private var previous: Sample?
    private var delivered = false
    func start(view: NSView, receive: @escaping (Sample?) -> Void) {
        self.view = view; self.receive = receive
        guard timer == nil else { return }
        delivered = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.02; self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }
    func stop() { timer?.invalidate(); timer=nil; view=nil; receive=nil; previous=nil; delivered=false }
    deinit { timer?.invalidate() }
    private func tick() {
        let sample = current()
        guard !delivered || previous != sample else { return }
        previous=sample; delivered=true; receive?(sample)
    }
    private func current() -> Sample? {
        guard let view, !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty,
              let window=view.window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible), let screen=window.screen,
              view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let mouse=NSEvent.mouseLocation
        guard screen.frame.contains(mouse) else { return nil }
        let point=view.convert(window.convertPoint(fromScreen:mouse),from:nil)
        let rangeX=max(160,screen.frame.width*0.28), rangeY=max(120,screen.frame.height*0.28)
        let x=point.x-view.bounds.minX
        let y=view.isFlipped ? point.y-view.bounds.minY : view.bounds.maxY-point.y
        // Relative surface coordinates only; no absolute desktop coordinates,
        // clicks, keystrokes, screen content or pointer history leave this object.
        func rounded(_ n:Double)->Double { (n*2).rounded()/2 }
        return .init(x:rounded(min(view.bounds.width+rangeX,max(-rangeX,x))),
                     y:rounded(min(view.bounds.height+rangeY,max(-rangeY,y))),
                     rangeX:rangeX,rangeY:rangeY)
    }
}
#endif
