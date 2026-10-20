import SwiftUI

/// A shared expanded composition. The embedding product owns presentation,
/// explicit consent, once-per-holiday receipts, focus and dismissal. This view
/// has no window-opening, capture, account, audio or action capability.
public struct PluginHolidayCelebration: View {
    public var scene: PluginSeasonalScene
    public var preview: Bool
    public var close: () -> Void
    @Environment(\.pluginAppearance) private var appearance
    public init(scene:PluginSeasonalScene,preview:Bool = false,close:@escaping ()->Void) {
        self.scene=scene;self.preview=preview;self.close=close
    }
    public var body:some View {
        GeometryReader { geometry in
            let size=min(260,max(80,min(geometry.size.width*0.17,geometry.size.height*0.29)))
            let avatarFrame=PluginSeasonalRectangle(x:0.30,y:0.28,width:0.40,height:0.30)
            PluginHolidaySurface(scene:scene,layout:.init(avatar:avatarFrame,protectedRegions:[.init(x:0.18,y:0.76,width:0.64,height:0.22)])) {
                ZStack {
                    HStack(spacing:size*0.10) {
                        PluginPresenceMark(size:size,persona:.nero)
                        PluginPresenceMark(size:size,persona:.ember)
                    }.position(x:geometry.size.width*0.5,y:geometry.size.height*0.43)
                    VStack(spacing:10) {
                        Text(scene.holiday.title).font(.system(size:min(54,geometry.size.width*0.04),weight:.semibold,design:.rounded))
                        Text(PluginSeasonalArtPlan.make(scene:scene)?.message ?? (preview ? "Preview · day \(scene.day) of \(scene.totalDays)" : scene.holiday.isReflective ? "A quiet moment of remembrance." : "A little celebration, within reach."))
                            .multilineTextAlignment(.center).frame(maxWidth:min(1400,geometry.size.width*0.80))
                            .font(.system(size:min(32,max(17,geometry.size.width*0.008)),weight:.medium))
                            .padding(.horizontal,24).padding(.vertical,16)
                            .foregroundStyle(Color(pluginHex:appearance.palette.text))
                            .background(Color(pluginHex:appearance.palette.background).opacity(appearance.reduceTransparency ? 1:0.80),in:RoundedRectangle(cornerRadius:20))
                        Button("Close celebration",action:close).buttonStyle(.borderedProminent).controlSize(.large)
                            .keyboardShortcut(.cancelAction).accessibilityIdentifier("holiday.close")
                    }.position(x:geometry.size.width*0.5,y:geometry.size.height*0.85)
                }
            }.background(Color(pluginHex:appearance.palette.background))
                .foregroundStyle(Color(pluginHex:appearance.palette.text))
                .tint(Color(pluginHex:appearance.palette.accent))
        }.ignoresSafeArea()
    }
}
