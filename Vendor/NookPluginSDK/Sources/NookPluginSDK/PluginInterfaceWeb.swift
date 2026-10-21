import Foundation

/// Optional shared chrome for custom views. Add `data-nook-ui` to the document
/// root to opt in; imagery, SVG fills and embedded maps are never recolored.
public enum PluginInterfaceWeb {
    public static let css = #"""
/* Nearly Nothing shared interface, opt in with data-nook-ui. Hardware art and embedded provider maps retain original colors. */
html[data-nook-ui] {font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; color:var(--nook-text); background:var(--nook-background); -webkit-font-smoothing:antialiased}
html[data-nook-ui] body {background:var(--nook-background);color:var(--nook-text)}
html[data-nook-ui] :is(button:not([data-nook-hardware]),input,textarea,select) {font:inherit}
html[data-nook-ui] :is(button:not([data-nook-hardware]),select,input:not([type=checkbox]):not([type=range]),textarea) {border-radius:var(--nook-control-radius,12px)}
html[data-nook-ui] :is(button:not([data-nook-hardware]),select) {min-height:30px; color:var(--nook-text); background-color:var(--nook-surface);border:1px solid color-mix(in srgb,var(--nook-border) 65%,transparent)}
html[data-nook-ui] button:not([data-nook-hardware]):hover:not(:disabled) {background-color:var(--nook-elevated);border-color:var(--nook-border)}
html[data-nook-ui] button:not([data-nook-hardware]):disabled {cursor:default;opacity:.45}
html[data-nook-ui] :is(input,textarea,select) {color:var(--nook-text);accent-color:var(--nook-accent)}
html[data-nook-ui] :is(input,textarea)::placeholder {color:var(--nook-secondary);opacity:1}
html[data-nook-ui] :is(button:not([data-nook-hardware]),input,select,textarea,a,summary):focus-visible {outline:2px solid var(--nook-focus);outline-offset:3px}
html[data-nook-ui] :is(.primary,button:not([data-nook-hardware]).primary) {background:var(--nook-accent);color:var(--nook-on-accent);border-color:transparent}
html[data-nook-ui] :is(.primary,button:not([data-nook-hardware]).primary):hover:not(:disabled) {background:var(--nook-accent);filter:brightness(1.08)}
html[data-nook-ui] :is(h1,h2,h3) {letter-spacing:-.035em;font-weight:600}
html[data-nook-ui] :is(.muted,.help,.eyebrow,.context) {color:var(--nook-secondary)}
html[data-nook-ui] details.nook-options {border:1px solid color-mix(in srgb,var(--nook-border) 65%,transparent);border-radius:var(--nook-control-radius);background:var(--nook-surface);padding:10px 14px}
html[data-nook-ui] details.nook-options>summary {cursor:pointer;color:var(--nook-secondary);font-size:12px;font-weight:500}
html[data-nook-ui] details.nook-options[open]>summary {margin-bottom:12px;color:var(--nook-text)}
html[data-nook-ui] .nook-option-grid {display:flex;align-items:center;flex-wrap:wrap;gap:10px 18px}
html[data-nook-ui] .nook-option-grid label {display:flex;gap:8px;align-items:center}
html[data-nook-ui] .nook-line-icon {width:18px;height:18px;display:block;fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round;flex-shrink:0}
html[data-nook-ui] .nook-reading-card {background:var(--nook-surface);border:1px solid color-mix(in srgb,var(--nook-border) 60%,transparent);border-radius:var(--nook-corner-radius);box-shadow:0 4px 20px #00000005}
html[data-nook-ui][data-nook-contrast="true"] :is(button:not([data-nook-hardware]),select,details.nook-options,.nook-reading-card) {border-color:var(--nook-border);border-width:2px}
@media(prefers-reduced-motion:reduce){html[data-nook-ui] * {animation:none!important;transition:none!important;scroll-behavior:auto!important}}

html[data-nook-ui] .nook-presence{background:radial-gradient(circle at 30% 25%,#fff 5%,#f6efec 32%,#ddd8e8 63%,#bccfe1 100%);border:1px solid #ffffffb3;box-shadow:0 0 0 3px #cdbb9f15,inset -3px -3px 9px #b6b3c233;color:var(--nook-text)}
html[data-nook-ui][data-nook-reduce-motion="true"] .voiceOrb{transform:none!important}
"""# + PluginGlassWeb.css + PluginGlassWeb.presenceCSS + PluginDotWaveWeb.css + PluginAvatarWeb.css + PluginConversationWeb.css + PluginHolidayWeb.css
    public static var bootstrap: String {
        let literal = String(data: try! JSONEncoder().encode(css), encoding: .utf8)!
        return "(() => { const apply=()=>{ if (!document.documentElement.hasAttribute('data-nook-ui')) return; const s=document.createElement('style'); s.id='nook-interface'; s.textContent=\(literal); document.head.append(s); }; if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',apply,{once:true}); else apply(); })();" + PluginDotWaveWeb.bootstrap + PluginMotionWeb.bootstrap + PluginAvatarWeb.bootstrap + PluginHolidayWeb.bootstrap
    }
}
