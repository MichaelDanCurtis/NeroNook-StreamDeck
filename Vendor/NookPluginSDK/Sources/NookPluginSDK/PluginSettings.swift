import SwiftUI
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

/// Shared, scrollable settings structure. Required choices remain in content;
/// diagnostics and specialist choices belong in PluginAdvancedSection.
public struct PluginSettingsPage<Content: View, Footer: View>: View {
    private let title: String, subtitle: String, symbol: String
    private let width: CGFloat, height: CGFloat
    private let done: (() -> Void)?
    private let content: Content
    private let footer: Footer
    @Environment(\.pluginAppearance) private var appearance
    public init(_ title: String, subtitle: String, symbol: String = "slider.horizontal.3", width: CGFloat = 700, height: CGFloat = 650, done: (() -> Void)? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title=title; self.subtitle=subtitle; self.symbol=symbol; self.width=width; self.height=height; self.done=done; self.content=content(); self.footer=footer()
    }
    private var size: CGSize {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let screen=NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == appearance.screenNumber } ?? NSScreen.main
        let frame=screen?.visibleFrame ?? CGRect(x:0,y:0,width:1280,height:800)
        return CGSize(width:min(width,max(300,frame.width-48)),height:min(height,max(320,frame.height-72)))
        #else
        return CGSize(width:width,height:height)
        #endif
    }
    public var body: some View {
        VStack(spacing:0) {
            HStack(alignment:.top,spacing:14) {
                Image(systemName:symbol).font(.system(size:22,weight:.medium)).foregroundStyle(Color(pluginHex:appearance.palette.accent)).frame(width:44,height:44).background(Color(pluginHex:appearance.palette.surface),in:RoundedRectangle(cornerRadius:14))
                VStack(alignment:.leading,spacing:5) { Text(title).font(.system(size:24,weight:.semibold)); Text(subtitle).font(.callout).foregroundStyle(Color(pluginHex:appearance.palette.secondary)).fixedSize(horizontal:false,vertical:true) }
                Spacer(minLength:8)
                if let done { Button("Done",action:done).keyboardShortcut(.cancelAction) }
            }.padding(24).pluginReveal(index:0)
            Divider()
            ScrollView { VStack(alignment:.leading,spacing:18) { content }.frame(maxWidth:.infinity,alignment:.leading).padding(24) }
            VStack(spacing:0) { footer }.padding(.horizontal,24).padding(.bottom,18)
        }.frame(width:size.width,height:size.height)
            .textFieldStyle(.roundedBorder)
            .foregroundStyle(Color(pluginHex:appearance.palette.text))
            .background(PluginGlassSurface(radius:0))
    }
}
extension PluginSettingsPage where Footer == EmptyView {
    public init(_ title:String, subtitle:String, symbol:String="slider.horizontal.3", width:CGFloat=700, height:CGFloat=650, done:(()->Void)?=nil, @ViewBuilder content:()->Content) {
        self.init(title,subtitle:subtitle,symbol:symbol,width:width,height:height,done:done,content:content,footer:{EmptyView()})
    }
}
public struct PluginSettingsSection<Content:View>:View {
    private let title:String, detail:String
    private let content:Content
    public init(_ title:String, detail:String="", @ViewBuilder content:()->Content) {self.title=title;self.detail=detail;self.content=content()}
    public var body:some View {
        PluginSettingsCard {
            VStack(alignment:.leading,spacing:13) {
                VStack(alignment:.leading,spacing:5) { Text(title).font(.headline); if !detail.isEmpty { Text(detail).font(.callout).pluginSecondaryText().fixedSize(horizontal:false,vertical:true) } }
                content
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
}
/// Also available to Catalyst: a common opaque reading surface, not a material
/// behind long text or credential fields.
public struct PluginSettingsCard<Content:View>:View {
    @Environment(\.pluginAppearance) private var appearance
    private let content:Content
    public init(@ViewBuilder content:()->Content) {self.content=content()}
    public var body:some View {
        content.padding(18 * appearance.theme.style.spacingScale)
            .background(Color(pluginHex:appearance.palette.surface),in:RoundedRectangle(cornerRadius:appearance.theme.style.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius:appearance.theme.style.cornerRadius).strokeBorder(Color(pluginHex:appearance.palette.border).opacity(appearance.increasedContrast ? 1:0.22),lineWidth:appearance.increasedContrast ? 2:appearance.theme.style.borderWidth))
    }
}
public struct PluginAdvancedSection<Content:View>:View {
    private let title:String, detail:String
    private let content:Content
    @State private var expanded=false
    public init(_ title:String="Advanced", detail:String, @ViewBuilder content:()->Content) {self.title=title;self.detail=detail;self.content=content()}
    public var body:some View {
        PluginSettingsCard {
            DisclosureGroup(title,isExpanded:$expanded) {
                VStack(alignment:.leading,spacing:14) { Text(detail).font(.callout).pluginSecondaryText().fixedSize(horizontal:false,vertical:true);content }.padding(.top,14).frame(maxWidth:.infinity,alignment:.leading)
            }.font(.callout.weight(.medium))
        }
    }
}

private struct PluginPrimaryAction: ViewModifier {
    @Environment(\.pluginAppearance) private var appearance
    func body(content: Content) -> some View {
        content.buttonStyle(.borderedProminent)
            .tint(Color(pluginHex: appearance.palette.accent))
            .foregroundStyle(Color(pluginHex: appearance.palette.onAccent))
    }
}
public extension View {
    /// Keep native focus and activation behavior while using the theme's
    /// contrast-checked label on its accent color in both appearances.
    func pluginPrimaryAction() -> some View { modifier(PluginPrimaryAction()) }
}

private struct PluginSecondaryText: ViewModifier {
    @Environment(\.pluginAppearance) private var appearance
    func body(content: Content) -> some View {
        content.foregroundStyle(Color(pluginHex: appearance.palette.secondary))
    }
}
public extension View {
    /// Use the palette's checked secondary color instead of applying opacity
    /// to primary text, which can lose contrast on light reading surfaces.
    func pluginSecondaryText() -> some View { modifier(PluginSecondaryText()) }
}
