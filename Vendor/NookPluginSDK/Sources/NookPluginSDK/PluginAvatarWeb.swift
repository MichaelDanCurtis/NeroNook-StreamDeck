import Foundation

/// Shared offline GLB rendering. Only the fixed bundled script is loaded; model
/// buffers/textures are data URLs. No network, microphone or private viewer API.
public enum PluginAvatarWeb {
    public static let css = #"""
html[data-nook-ui] .nook-presence{display:inline-block;position:relative;overflow:visible;background-image:none!important;background:none!important;border:0!important;box-shadow:none!important;filter:none!important}
html[data-nook-ui] .nook-presence::before{content:"";position:absolute;inset:10% 3% -2%;border:0!important;background:radial-gradient(ellipse at 50% 88%,#49443830,transparent 48%),radial-gradient(ellipse at 50% 45%,#baaea018,transparent 68%);border-radius:50%;pointer-events:none}
html[data-nook-scheme="dark"] .nook-presence::before{background:radial-gradient(ellipse at 50% 65%,#ddcab918,transparent 67%)}
html[data-nook-ui] .nook-presence::after{content:attr(data-nook-season);position:absolute;left:-8%;right:-8%;bottom:0;font-size:22px;letter-spacing:12px;border:0!important;transform:none!important;pointer-events:none;text-align:center}
html[data-nook-contrast="true"] .nook-presence::after,html[data-nook-reduce-transparency="true"] .nook-presence::after{display:none}
.nook-presence[data-nook-interactive="true"]{cursor:pointer} .nook-presence[data-nook-interactive="true"]:focus-visible{outline:2px solid currentColor;outline-offset:6px;border-radius:40%!important} .nook-avatar-caption{position:absolute;top:98%;left:-25%;right:-25%;text-align:center;font:500 11px system-ui;white-space:nowrap;pointer-events:none;opacity:.7} .nook-presence nook-avatar-model{display:block;width:100%;height:100%;background:transparent;--poster-color:transparent;--progress-bar-height:0px;--progress-bar-color:transparent;pointer-events:none}
.nook-avatar-menu{position:fixed;z-index:2147483000;display:grid;width:188px;padding:6px;gap:3px;border-radius:16px;color:var(--nook-text,#f5f2ed);background:var(--nook-surface,#262626);border:1px solid var(--nook-border,#666);box-shadow:0 10px 36px #0004;backdrop-filter:blur(18px)}.nook-avatar-menu button{font:500 12px system-ui;text-align:left;padding:9px 11px;color:inherit;border:0;border-radius:11px;background:transparent;cursor:pointer}.nook-avatar-menu button:hover,.nook-avatar-menu button:focus-visible{background:var(--nook-elevated,#444);outline:2px solid var(--nook-focus,#aaa);outline-offset:-2px}
"""#
    public static let bootstrap: String = {
        guard let url=Bundle.module.url(forResource:"avatar-surface",withExtension:"js"),let source=try? String(contentsOf:url,encoding:.utf8) else {return ""}
        return source
    }()
}
