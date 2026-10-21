import Foundation

/// Generic opt-in decoration for custom views. Templates come from the same
/// validated plan as native surfaces; neither code nor assets arrive remotely.
public enum PluginHolidayWeb {
    public static let css = """
    body[data-nook-seasonal-surface]{isolation:isolate}
    .nook-seasonal-canvas{position:fixed;inset:0;width:100%;height:100%;z-index:-1;pointer-events:none}
    [data-nook-seasonal-message-slot]{max-width:720px;margin:8px auto;padding:12px 20px;white-space:pre-line;text-align:center;font-size:clamp(13px,2vw,19px);line-height:1.45;background:var(--nook-surface);color:var(--nook-text);border-radius:18px;backdrop-filter:blur(18px)}
    [data-nook-seasonal-message-slot][hidden]{display:none}
    .nook-seasonal-quiet-welcome .nc-stage>.nc-title,.nook-seasonal-quiet-welcome .nc-stage>.nc-subtitle,.nook-seasonal-has-message>.nc-title,.nook-seasonal-has-message>.nc-subtitle{display:none}
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
