#if canImport(UIKit)
import UIKit
import SwiftUI
import Combine

/// Catalyst/extension fallback uses the shared context. An embedding host can
/// supply a validated surface context explicitly; UIKit does not expose macOS
/// NSScreenNumber identities for independently moved Catalyst windows.
@MainActor public final class PluginAppearanceStore: ObservableObject {
    public static let shared = PluginAppearanceStore()
    @Published public private(set) var delivery: PluginAppearanceDelivery?
    private var identity: (String,UUID)?
    private var observations:[AnyCancellable]=[]
    public init() {
        for name in [UIApplication.didBecomeActiveNotification,UIAccessibility.reduceMotionStatusDidChangeNotification,UIAccessibility.reduceTransparencyStatusDidChangeNotification,UIAccessibility.darkerSystemColorsStatusDidChangeNotification] {
            NotificationCenter.default.publisher(for:name).receive(on:RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in:&observations)
        }
    }
    public func beginSession(pluginID:String,session:UUID) { guard identity?.0 != pluginID || identity?.1 != session else{return};identity=(pluginID,session);delivery=nil }
    @discardableResult public func receive(_ message:PluginMessage)->Bool {
        guard message.apiVersion==1,message.type=="appearance",message.pluginID==identity?.0,message.session==identity?.1,let value=message.appearance else{return false}
        return update(value)
    }
    @discardableResult public func update(_ value:PluginAppearanceDelivery)->Bool { guard (try? value.validate()) != nil,delivery.map({value.revision>$0.revision}) ?? true else{return false};delivery=value;return true }
    public func context(screenNumber:UInt32?=nil,fallback:ColorScheme)->PluginAppearanceContext {
        var value=screenNumber.flatMap { number in delivery?.displays.first { $0.screenNumber==number } } ?? delivery?.shared ?? .init()
        if value.mode == .system { value.scheme = fallback == .dark ? .dark:.light }
        value.reduceTransparency=UIAccessibility.isReduceTransparencyEnabled;value.reduceMotion=UIAccessibility.isReduceMotionEnabled;value.increasedContrast=UIAccessibility.isDarkerSystemColorsEnabled
        return value
    }
}
private struct PluginAppearanceKey:EnvironmentKey { static let defaultValue=PluginAppearanceContext() }
extension EnvironmentValues { public var pluginAppearance:PluginAppearanceContext { get{self[PluginAppearanceKey.self]} set{self[PluginAppearanceKey.self]=newValue} } }
extension Color { public init(pluginHex:String) { let n=UInt32(pluginHex.dropFirst(),radix:16) ?? 0;self.init(.sRGB,red:Double((n>>16)&255)/255,green:Double((n>>8)&255)/255,blue:Double(n&255)/255,opacity:1) } }
public struct PluginThemedRoot<Content:View>:View {
    @ObservedObject private var store:PluginAppearanceStore
    @Environment(\.colorScheme) private var systemScheme
    private let content:Content
    private let fillsBackground:Bool
    public init(store:PluginAppearanceStore = .shared,background:Bool=true,@ViewBuilder content:()->Content) {self.store=store;self.fillsBackground=background;self.content=content()}
    public var body:some View { let appearance=store.context(fallback:systemScheme);content.buttonStyle(PluginGlassButtonStyle()).environment(\.pluginAppearance,appearance).preferredColorScheme(appearance.mode == .system ? nil:appearance.scheme == .dark ? .dark:.light).tint(Color(pluginHex:appearance.palette.accent)).foregroundStyle(Color(pluginHex:appearance.palette.text)).background { if fillsBackground { PluginGlassSurface(radius:0).environment(\.pluginAppearance,appearance) } } }
}
extension View { public func pluginThemed(background:Bool=true)->some View { PluginThemedRoot(background:background) {self} } }
#endif
