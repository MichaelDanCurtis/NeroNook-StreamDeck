import Foundation

/// Static package identity, available before the plugin starts. Not a status indicator.
public struct PluginIcon: Codable, Equatable, Sendable {
    public var symbol: String
    public var color: String
    public var badge: String?
    public init(symbol: String, color: String = "7C83FF", badge: String? = nil) {
        self.symbol = symbol; self.color = color; self.badge = badge
    }
    public func validate() throws {
        let validSymbol: (String) -> Bool = {
            !$0.isEmpty && $0.count <= 80 && $0.range(of: "^[a-z0-9]+([.][a-z0-9]+)*$", options: .regularExpression) != nil
        }
        guard validSymbol(symbol), badge.map(validSymbol) ?? true,
              color.range(of: "^[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
            throw ModuleProblem("Invalid module icon. Use an SF Symbol name and six-digit RGB color.")
        }
    }
}

#if os(macOS)
import AppKit
import SwiftUI

/// The same scalable treatment for a host selector, module header or plugin-owned window.
public struct PluginIconView: View {
    public var icon: PluginIcon
    public var size: CGFloat
    public init(_ icon: PluginIcon, size: CGFloat = 32) { self.icon = icon; self.size = size }
    private var tint: Color {
        let rgb = UInt32(icon.color, radix: 16) ?? 0x7C83FF
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    private var symbol: String {
        NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil) == nil ? "square.stack.3d.up.fill" : icon.symbol
    }
    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.38), tint.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(tint.opacity(0.42), lineWidth: 0.75)
            Image(systemName: symbol).font(.system(size: size * 0.54, weight: .semibold)).foregroundStyle(tint)
            if let badge = icon.badge, NSImage(systemSymbolName: badge, accessibilityDescription: nil) != nil {
                Image(systemName: badge).font(.system(size: size * 0.24, weight: .bold)).foregroundStyle(.white)
                    .frame(width: size * 0.39, height: size * 0.39).background(tint.opacity(0.9), in: Circle())
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
                    .offset(x: size * 0.32, y: size * 0.32)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
#endif
