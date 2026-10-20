import Foundation

/// Bundled glass and motion primitives shared by independent web surfaces.
public enum PluginGlassWeb {
    public static let css = #"""

/* Glass chrome; content, maps, device art and credential fields keep their colors. */
html[data-nook-ui]{background:transparent}
html[data-nook-ui] body{background:radial-gradient(ellipse at 5% 0%,color-mix(in srgb,var(--nook-accent) 9%,transparent),transparent 65%),linear-gradient(135deg,#ffffff0b,transparent 60%),color-mix(in srgb,var(--nook-background) var(--nook-glass-tint,52%),transparent)}
html[data-nook-ui] :is(header,footer,aside,.talkBar,.compose,.nook-glass){background-color:color-mix(in srgb,var(--nook-surface) 56%,transparent);background-image:linear-gradient(125deg,#ffffff14,transparent 60%);box-shadow:inset 0 1px #ffffff20;backdrop-filter:blur(20px) saturate(1.15);-webkit-backdrop-filter:blur(20px) saturate(1.15)}
html[data-nook-ui] :is(button:not([data-nook-hardware]),select,details.nook-options){background-image:linear-gradient(120deg,#ffffff20,#ffffff03 60%);box-shadow:inset 0 1px #ffffff20,0 2px 5px #00000008;transition:background-color 140ms,border-color 140ms,box-shadow 140ms}
html[data-nook-ui] button:not([data-nook-hardware]):hover:not(:disabled){box-shadow:inset 0 1px #ffffff40,0 3px 9px #00000012}
html[data-nook-ui] button:not([data-nook-hardware]):active:not(:disabled){box-shadow:inset 0 1px 4px #00000018}
html[data-nook-ui] :is(.nook-reading-card,textarea,input:not([type=checkbox]):not([type=range])){background-color:var(--nook-surface)}
html[data-nook-ui][data-nook-reduce-transparency="true"] body,html[data-nook-ui][data-nook-contrast="true"] body{background:var(--nook-background)}
html[data-nook-ui][data-nook-reduce-transparency="true"] :is(header,footer,aside,.talkBar,.compose,.nook-glass),html[data-nook-ui][data-nook-contrast="true"] :is(header,footer,aside,.talkBar,.compose,.nook-glass){background:var(--nook-surface);backdrop-filter:none;-webkit-backdrop-filter:none;box-shadow:none}
@media(prefers-reduced-transparency:reduce){html[data-nook-ui] body{background:var(--nook-background)}html[data-nook-ui] :is(header,footer,aside,.talkBar,.compose,.nook-glass){background:var(--nook-surface);backdrop-filter:none;-webkit-backdrop-filter:none}}

/* Nearly Nothing: diffuse control light, uninterrupted glass, quiet boundaries.
   Palettes remain user-selected, including Circuit; treatment is no longer an outline. */
html[data-nook-ui] body{background:radial-gradient(ellipse at 12% 0%,#ffffff0a,transparent 65%),color-mix(in srgb,var(--nook-background) 62%,transparent);background-size:auto}
html[data-nook-ui] :is(header,footer,aside,.talkBar,.compose,.nook-glass){border-color:color-mix(in srgb,var(--nook-border) 22%,transparent);box-shadow:none;background-image:linear-gradient(120deg,#ffffff0c,transparent 65%)}
html[data-nook-ui] :is(button:not([data-nook-hardware]),select){border-radius:max(18px,var(--nook-control-radius));border-color:color-mix(in srgb,var(--nook-border) 28%,transparent);background-color:color-mix(in srgb,var(--nook-elevated) 72%,transparent);background-image:radial-gradient(ellipse at 50% 0%,#ffffff16,transparent 85%);box-shadow:0 2px 8px #00000006;transition:background-color 160ms,box-shadow 160ms,filter 160ms}
html[data-nook-ui] button:not([data-nook-hardware]):hover:not(:disabled){border-color:color-mix(in srgb,var(--nook-border) 35%,transparent);background-color:color-mix(in srgb,var(--nook-elevated) 90%,transparent);box-shadow:0 0 22px color-mix(in srgb,var(--nook-accent) 10%,transparent)}
html[data-nook-ui] button:not([data-nook-hardware]):active:not(:disabled){box-shadow:inset 0 2px 6px #00000010}
html[data-nook-ui] :is(button:not([data-nook-hardware]).primary,.primary){background-color:color-mix(in srgb,var(--nook-accent) 16%,var(--nook-surface));background-image:radial-gradient(ellipse at 50% 50%,color-mix(in srgb,var(--nook-accent) 9%,transparent),transparent 85%);color:var(--nook-text);border-color:color-mix(in srgb,var(--nook-accent) 20%,transparent);box-shadow:0 0 24px color-mix(in srgb,var(--nook-accent) 8%,transparent)}
html[data-nook-ui] :is(button:not([data-nook-hardware]).primary,.primary):hover:not(:disabled){background-color:color-mix(in srgb,var(--nook-accent) 23%,var(--nook-surface));filter:none}
html[data-nook-ui] :is(.talkBar,.compose,.nook-reading-card,details.nook-options){border-radius:max(18px,var(--nook-corner-radius));border-color:color-mix(in srgb,var(--nook-border) 24%,transparent);box-shadow:none}
html[data-nook-ui] :is(input:not([type=checkbox]):not([type=range]),textarea){border-color:color-mix(in srgb,var(--nook-border) 30%,transparent)}
html[data-nook-ui][data-nook-reduce-transparency="true"] :is(button:not([data-nook-hardware]),select),html[data-nook-ui][data-nook-contrast="true"] :is(button:not([data-nook-hardware]),select){background-color:var(--nook-elevated);background-image:none}
html[data-nook-ui][data-nook-reduce-transparency="true"] body,html[data-nook-ui][data-nook-contrast="true"] body{background:var(--nook-background)}
html[data-nook-ui][data-nook-contrast="true"] :is(button:not([data-nook-hardware]),select,details.nook-options,.talkBar,.compose,.nook-reading-card){border:2px solid var(--nook-border);box-shadow:none}
html[data-nook-ui][data-nook-contrast="true"] :is(button:not([data-nook-hardware]).primary,.primary){background:var(--nook-accent);color:var(--nook-on-accent)}
@media(prefers-reduced-transparency:reduce){html[data-nook-ui] body{background:var(--nook-background)}html[data-nook-ui] :is(button:not([data-nook-hardware]),select){background-color:var(--nook-elevated);background-image:none}}

"""#
    public static let presenceCSS = #"""
html[data-nook-ui] .nook-presence{position:relative;flex:none;vertical-align:middle;background-image:url("nook-view://surface/__nook_sdk__/presence.png")!important;background-color:transparent!important;border:0!important;border-radius:0!important;box-shadow:none!important;filter:none!important;background-size:contain;background-position:center;background-repeat:no-repeat;animation:nook-presence-float 7.6s ease-in-out infinite}
.nook-presence:after{display:none!important}
@keyframes nook-presence-float{0%,100%{translate:0 2px;rotate:-1.5deg}50%{translate:0 -3px;rotate:1.5deg}}
html[data-nook-ui] body{position:relative;isolation:isolate}
/* Decorative background artwork is paused; persona artwork remains. */
html[data-nook-document-hidden="true"] .nook-presence{animation-play-state:paused!important}
html[data-nook-reduce-motion="true"] .nook-presence{animation:none!important;transform:none!important;translate:none!important;rotate:none!important;scale:none!important}
@media(prefers-reduced-motion:reduce){.nook-presence{animation:none!important;transform:none!important;translate:none!important;rotate:none!important;scale:none!important}}
"""#
}
