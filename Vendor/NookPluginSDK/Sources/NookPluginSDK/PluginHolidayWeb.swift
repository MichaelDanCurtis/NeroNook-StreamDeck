import Foundation

/// Generic opt-in decoration for custom views. Templates come from the same
/// validated plan as native surfaces; neither code nor assets arrive remotely.
public enum PluginHolidayWeb {
    public static let css = """
    body[data-nook-seasonal-surface]{isolation:isolate}
    .nook-seasonal-canvas{position:fixed;inset:0;width:100%;height:100%;z-index:-1;pointer-events:none}
    body[data-nook-seasonal-active] .nook-presence::after{content:none!important}
    """
    public static let bootstrap:String = {
        guard let catalog=PluginSeasonalArtCatalog.bundled,
              let url=Bundle.module.url(forResource:"seasonal-surface",withExtension:"js"),
              let script=try? String(contentsOf:url,encoding:.utf8) else { return "" }
        var plans:[String:PluginSeasonalArtPlan]=[:]
        for holiday in PluginHoliday.allCases {
            for day in 1...holiday.stageDays {
                if let scene=try? PluginSeasonalScene.preview(holiday:holiday,day:day),let plan=PluginSeasonalArtPlan.make(scene:scene) {
                    plans[holiday.rawValue+".\(day)"]=plan
                }
            }
        }
        struct Payload:Encodable { var catalog:PluginSeasonalArtCatalog;var plans:[String:PluginSeasonalArtPlan] }
        guard let data=try? JSONEncoder().encode(Payload(catalog:catalog,plans:plans)),let json=String(data:data,encoding:.utf8) else { return "" }
        return "(()=>{const seasonalData="+json+";\n"+script+"\n})();"
    }()
}
