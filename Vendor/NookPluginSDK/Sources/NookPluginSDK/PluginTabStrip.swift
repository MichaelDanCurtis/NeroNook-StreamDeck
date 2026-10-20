import SwiftUI

public struct PluginTabChoice: Identifiable {
    public let id: String
    public let title: String
    public init(_ id:String,_ title:String) { self.id=id;self.title=title }
}

/// Quiet capsule tabs for a compact module. Selection never shifts layout.
public struct PluginTabStrip: View {
    public let label:String
    public let choices:[PluginTabChoice]
    @Binding private var selection:String
    @Environment(\.pluginAppearance) private var appearance
    public init(_ label:String,selection:Binding<String>,choices:[PluginTabChoice]) {
        self.label=label;self._selection=selection;self.choices=choices
    }
    public var body:some View {
        HStack(spacing:3) {
            ForEach(choices) { choice in
                let selected=selection == choice.id
                Button { selection=choice.id } label: {
                    Text(choice.title).font(.system(size:12,weight:selected ? .semibold:.medium))
                        .lineLimit(1).frame(maxWidth:.infinity).frame(height:24)
                        .contentShape(Capsule())
                        .background {
                            if selected {
                                Capsule().fill(Color(pluginHex:appearance.palette.elevated))
                                    .overlay(Capsule().fill(Color(pluginHex:appearance.palette.accent).opacity(0.09)))
                            }
                        }
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected:[])
                    .accessibilityLabel(choice.title)
            }
        }.padding(2).frame(height:28)
            .background(Color(pluginHex:appearance.palette.surface).opacity(appearance.reduceTransparency ? 1:0.5),in:Capsule())
            .overlay(Capsule().strokeBorder(Color(pluginHex:appearance.palette.border).opacity(appearance.increasedContrast ? 1:0.12),lineWidth:appearance.increasedContrast ? 2:0.5))
            .accessibilityElement(children:.contain).accessibilityLabel(label)
    }
}
