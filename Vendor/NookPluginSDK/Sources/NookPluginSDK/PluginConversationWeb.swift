import Foundation

/// Nearly Nothing composition for speech and chat surfaces. Providers own their
/// state and controls; this stylesheet contains no account or audio behavior.
public enum PluginConversationWeb {
    public static let css = #"""
html[data-nook-ui] body.nc-app{padding:18px 24px;margin:0;height:100vh;overflow:hidden;display:flex;flex-direction:column;gap:12px;background:radial-gradient(ellipse at 50% 27%,color-mix(in srgb,var(--nook-accent) 5%,transparent),transparent 52%),color-mix(in srgb,var(--nook-background) 82%,transparent);color:var(--nook-text)}
html[data-nook-ui] .nc-app [hidden]{display:none!important}
html[data-nook-ui] .nc-app :is(header.nc-topbar,footer.nc-bottom){background:none;background-image:none;box-shadow:none;backdrop-filter:none;-webkit-backdrop-filter:none;border:0;padding:0}
.nc-topbar{height:36px;min-height:36px;display:flex;align-items:center;gap:10px;flex-shrink:0}
.nc-brand{font-size:15px;font-weight:600;letter-spacing:-.025em}.nc-brand small{font-size:11px;font-weight:400;color:var(--nook-secondary);margin-left:8px}
.nc-topbar .nc-spacer{flex:1}.nc-topbar .nc-status{font-size:11px;color:var(--nook-secondary);text-transform:none}
html[data-nook-ui] .nc-app .nc-icon{min-width:32px;height:32px;padding:6px 9px;border:0;background:transparent;box-shadow:none;border-radius:50%}
.nc-icon svg,.nc-mic svg{width:17px;height:17px;vertical-align:middle;fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round}
.nc-main{flex:1;min-height:0;position:relative;overflow:auto}
.nc-stage{height:100%;min-height:220px;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;gap:12px;padding:6px 18px 14px}
.nc-stage .nc-presence.nook-presence{width:130px;height:130px;flex:none;margin:0;transform:none!important}
html[data-nook-ui] .nc-app .nc-title{font-size:clamp(23px,3vw,34px);line-height:1.15;letter-spacing:-.04em;font-weight:500;margin:0;color:var(--nook-text)}
.nc-subtitle{font-size:13px;line-height:1.4;color:var(--nook-secondary);margin:0}
.nc-words{font-size:clamp(19px,2.6vw,28px);font-weight:400;line-height:1.35;letter-spacing:-.025em;max-width:600px;max-height:3.9em;overflow:auto;margin:8px 0 0;white-space:pre-wrap;overflow-wrap:anywhere}
.nc-wave{display:flex;justify-content:center;align-items:center;width:min(440px,85%);min-height:48px;margin:0 auto}
.nc-wave meter{width:100%}.nc-wave .nook-dot-wave{width:100%;height:48px;max-width:none}
.nc-bottom{display:flex;flex-direction:column;flex-shrink:0;gap:12px}
.nc-control-row{display:flex;align-items:center;justify-content:space-between;gap:12px;min-height:42px;flex-wrap:wrap}
html[data-nook-ui] .nc-control-row :is(button,select){font-size:12px;min-height:38px;padding:8px 15px;border-radius:999px;background-color:color-mix(in srgb,var(--nook-surface) 55%,transparent);border-color:color-mix(in srgb,var(--nook-border) 50%,transparent)}
html[data-nook-ui] .nc-app .nc-stop{color:var(--nook-accent);border-color:color-mix(in srgb,var(--nook-accent) 65%,transparent);background-color:color-mix(in srgb,var(--nook-accent) 6%,transparent)}
.nc-duplex{display:flex;padding:3px;gap:2px;border:1px solid color-mix(in srgb,var(--nook-border) 45%,transparent);border-radius:999px;background:color-mix(in srgb,var(--nook-surface) 40%,transparent)}
html[data-nook-ui] .nc-duplex button{min-height:30px;padding:5px 16px;border:0;background:transparent;box-shadow:none;color:var(--nook-secondary)}
html[data-nook-ui] .nc-duplex button[aria-pressed=true]{background:color-mix(in srgb,var(--nook-elevated) 80%,transparent);box-shadow:inset 0 1px #ffffff24;color:var(--nook-text)}
.nc-mic{display:flex;gap:8px;align-items:center;justify-content:center}.nc-text-link{border:0!important;background:none!important;box-shadow:none!important;color:var(--nook-secondary)!important;text-decoration:underline;text-underline-offset:3px;padding-inline:4px!important}
.nc-compose{display:flex;align-items:flex-end;gap:10px;border:1px solid color-mix(in srgb,var(--nook-border) 45%,transparent);border-radius:20px;padding:9px 10px 9px 16px;background:color-mix(in srgb,var(--nook-surface) 48%,transparent)}
.nc-compose textarea{flex:1;width:100%;resize:none;background:none!important;border:0!important;box-shadow:none;padding:6px 0;color:var(--nook-text);font:14px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;min-height:40px;max-height:100px}
.nc-compose button{border-radius:50%!important;width:36px;height:36px;min-height:36px!important;padding:5px!important}
.nc-menu{position:relative;font-size:12px;z-index:30}.nc-menu>summary{list-style:none;cursor:pointer;border-radius:50%;padding:7px 10px}.nc-menu>summary::-webkit-details-marker{display:none}
.nc-menu>div{position:absolute;right:0;top:36px;min-width:260px;max-height:min(420px,74vh);overflow:auto;padding:14px;display:flex;flex-direction:column;gap:10px;text-align:left;border-radius:18px;border:1px solid color-mix(in srgb,var(--nook-border) 60%,transparent);background:var(--nook-elevated);box-shadow:0 12px 32px #00000025}
.nc-menu label{display:flex;flex-direction:column;gap:5px;font-size:11px;color:var(--nook-secondary)}.nc-menu select{max-width:100%!important;width:100%;font-size:12px}.nc-menu button{text-align:left;font-size:12px}.nc-menu p{font-size:11px;line-height:1.45;margin:0;color:var(--nook-secondary)}
.nc-drawer{position:absolute;inset:0;z-index:20;padding:20px;background:var(--nook-background);border-radius:18px;overflow:auto}.nc-drawer h2{font-size:20px;margin:0}.nc-drawer .nc-topbar{margin-bottom:14px}
.nc-review{flex-shrink:0;border:1px solid var(--nook-border);background:var(--nook-elevated);padding:14px 18px;border-radius:18px;text-align:left;font-size:12px}.nc-review h3{margin:0 0 8px}.nc-review p{font-size:12px;line-height:1.5}.nc-review button{margin-right:8px}
.nc-notice{font-size:12px;line-height:1.4;color:var(--nook-secondary);margin:0;overflow-wrap:anywhere}.nc-notice:empty{display:none}.nc-error{color:var(--nook-error)}
html[data-nook-ui][data-nook-reduce-transparency=true] body.nc-app{background:var(--nook-background)}
html[data-nook-ui][data-nook-contrast=true] .nc-app :is(.nc-compose,.nc-duplex,.nc-control-row button,.nc-control-row select){border:1px solid var(--nook-text)}
@media(max-height:520px){html[data-nook-ui] body.nc-app{padding:12px 18px;gap:8px}.nc-topbar{height:30px;min-height:30px}.nc-stage{gap:8px;min-height:180px;padding:0 12px 8px}.nc-stage .nc-presence.nook-presence{width:96px;height:96px}.nc-title{font-size:25px}.nc-words{font-size:22px;max-height:2.8em;margin-top:3px}.nc-wave{min-height:34px}.nc-wave .nook-dot-wave{height:34px}.nc-bottom{gap:8px}}
@media(max-width:650px){.nc-control-row{gap:7px}.nc-duplex button{padding-inline:9px!important}.nc-control-row .nc-text-link{margin-left:auto}.nc-stage{padding-inline:0}.nc-stage .nc-presence.nook-presence{width:104px;height:104px}}

/* Concept 01: a composed voice stage above one visible glass control dock. */
html[data-nook-ui] body:is(.nc-agent,.nc-ember){background:radial-gradient(ellipse at 50% 24%,color-mix(in srgb,var(--nook-accent) 5%,transparent),transparent 58%),linear-gradient(145deg,color-mix(in srgb,var(--nook-elevated) 38%,transparent),color-mix(in srgb,var(--nook-background) 75%,transparent));padding:18px 26px 20px}
.nc-talking .nc-stage{justify-content:flex-start;gap:10px;min-height:0;padding:clamp(4px,2vh,18px) 18px 6px;max-width:780px;margin-inline:auto}
.nc-talking .nc-stage .nc-presence.nook-presence{width:112px;height:112px;margin:0 0 3px}
html[data-nook-ui] .nc-talking .nc-title{font-size:clamp(26px,3.3vw,36px);letter-spacing:-.035em;font-weight:450}
.nc-talking .nc-subtitle{font-size:14px}
html[data-nook-ui] body.nc-talking .nc-words{font-size:clamp(23px,3vw,32px);line-height:1.28;max-width:650px;margin:15px 0 3px;max-height:2.6em}
.nc-talking .nc-wave{width:min(600px,98%);gap:15px;min-height:58px;margin-top:8px}
.nc-wave-label{font-size:11px;color:var(--nook-secondary);white-space:nowrap;flex:none}
.nc-talking .nc-wave .nook-wave-wrap[data-wide]{width:auto;min-width:0;flex:1}
.nc-talking .nc-wave .nook-dot-wave{column-gap:clamp(3px,.55vw,6px);max-width:100%;overflow:hidden}
:is(.nc-agent,.nc-ember) .nc-wave .nook-dot-wave i:not([data-on]){opacity:0}
.nc-status[data-capturing=true]::before{content:"";display:inline-block;width:7px;height:7px;background:#f05a41;border-radius:50%;margin-right:7px}
.nc-control-row{justify-content:space-between;gap:10px}
html[data-nook-ui] :is(.nc-agent,.nc-ember) .nc-control-row :is(button,.nc-voice-controls>summary){min-height:40px;background:linear-gradient(180deg,color-mix(in srgb,var(--nook-elevated) 70%,transparent),color-mix(in srgb,var(--nook-surface) 42%,transparent));border:1px solid color-mix(in srgb,var(--nook-border) 40%,transparent);box-shadow:inset 0 1px #ffffff0c,0 3px 10px #00000010;border-radius:999px}
html[data-nook-ui] :is(.nc-agent,.nc-ember) .nc-control-row .nc-duplex button{border:0;box-shadow:none;background:transparent;min-height:30px}
html[data-nook-ui] :is(.nc-agent,.nc-ember) .nc-control-row .nc-duplex button[aria-pressed=true]{background:linear-gradient(180deg,color-mix(in srgb,var(--nook-text) 15%,var(--nook-surface)),color-mix(in srgb,var(--nook-elevated) 75%,transparent));box-shadow:inset 0 1px #ffffff18}
html[data-nook-ui] :is(.nc-agent,.nc-ember) .nc-control-row .nc-stop{color:var(--nook-accent);border-color:color-mix(in srgb,var(--nook-accent) 48%,transparent);background:color-mix(in srgb,var(--nook-accent) 6%,transparent)}
.nc-voice-pod{display:flex;align-items:center;gap:6px;min-width:0;position:relative}
.nc-voice-pod .nc-mic{min-width:145px;max-width:220px;gap:8px}
.nc-mic>span:first-of-type{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.nc-mic svg{flex:none}
.nc-voice-controls{position:relative;border:0!important;padding:0!important;margin:0!important;font-size:12px;z-index:50}
.nc-voice-controls>summary{font-size:12px;display:flex;align-items:center;gap:6px;padding:8px 12px;cursor:pointer;list-style:none;color:var(--nook-text)}
.nc-voice-controls>summary::-webkit-details-marker{display:none}
.nc-voice-controls svg{width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:1.5}
.nc-voice-controls .nc-voice-panel{position:absolute;bottom:calc(100% + 12px);right:0;width:310px;max-height:min(390px,72vh);overflow:auto;display:grid;gap:11px;padding:18px;border:1px solid color-mix(in srgb,var(--nook-border) 50%,transparent);border-radius:20px;background:var(--nook-elevated);box-shadow:0 14px 40px #00000030;text-align:left}
.nc-voice-panel strong{font-size:15px;font-weight:550}
.nc-voice-panel label{display:flex;justify-content:space-between;gap:10px;font-size:12px}
.nc-voice-panel output{font-variant-numeric:tabular-nums;color:var(--nook-secondary)}
.nc-voice-panel input[type=range]{width:100%;accent-color:var(--nook-accent);padding:0;margin:0}
.nc-range-labels{display:flex;justify-content:space-between;font-size:10px;color:var(--nook-secondary)}
.nc-voice-panel .nc-notice{font-size:11px;line-height:1.5}
.nc-voice-panel button{text-align:left;font-size:12px}
@media(max-height:520px){html[data-nook-ui] body:is(.nc-agent,.nc-ember){padding:12px 18px 14px}.nc-talking .nc-stage{gap:7px;padding-top:2px}.nc-talking .nc-stage .nc-presence.nook-presence{width:88px;height:88px}html[data-nook-ui] body.nc-talking .nc-words{font-size:25px;margin-top:10px;max-height:2.6em}.nc-talking .nc-wave{min-height:42px;margin-top:3px}.nc-talking .nc-wave .nook-dot-wave{height:42px}}
@media(max-width:720px){.nc-voice-pod .nc-mic{max-width:160px;min-width:130px}.nc-voice-controls>summary{padding-inline:9px}.nc-voice-controls>summary>span{display:none}.nc-control-row{gap:7px}.nc-talking .nc-wave{gap:9px}.nc-wave-label{font-size:10px}}
"""#
}
