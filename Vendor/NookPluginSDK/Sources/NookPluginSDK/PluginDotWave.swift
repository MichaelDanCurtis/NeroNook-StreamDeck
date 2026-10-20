import SwiftUI

/// A measured-input meter. It has no timer: silence is a quiet center line.
/// Feed normalized levels from the owning audio service; no audio is captured here.
public struct PluginDotWave: View {
    public var level: Double
    public var columns: Int
    public var tint: Color
    public init(level: Double, columns: Int = 21, tint: Color = .primary) {
        self.level = level; self.columns = max(3,min(41,columns)); self.tint = tint
    }
    public var body: some View {
        Canvas { context, size in
            let normalized = level.isFinite ? min(1,max(0,level)):0
            let step = min(size.width / CGFloat(columns),size.height / 7)
            let diameter = max(1,step * 0.48)
            let left = (size.width - CGFloat(columns-1) * step)/2
            for column in 0..<columns {
                let envelope = 0.15 + 0.85 * abs(sin(Double(column)*0.48))
                let rows = Int((normalized * 3 * envelope).rounded())
                for row in -3...3 {
                    let active = abs(row) <= rows
                    let dot = CGRect(x:left+CGFloat(column)*step-diameter/2,y:size.height/2+CGFloat(row)*step-diameter/2,width:diameter,height:diameter)
                    context.fill(Path(ellipseIn:dot),with:.color(tint.opacity(active ? 0.88:0.07)))
                }
            }
        }.accessibilityElement(children:.ignore).accessibilityLabel("Microphone level")
            .accessibilityValue("\(Int((level.isFinite ? min(1,max(0,level)):0)*100)) percent")
            .allowsHitTesting(false)
    }
}

/// Upgrade an opt-in HTML meter without removing its accessible name/value.
/// Values come from the plugin. No timers, fake audio, canvas loops or network.
public enum PluginDotWaveWeb {
    public static let css = #"""
html[data-nook-ui] .nook-wave-wrap{position:relative;display:inline-flex;align-items:center;justify-content:center;vertical-align:middle;min-width:56px;width:112px;height:28px;flex:none}
html[data-nook-ui] .nook-wave-wrap[hidden]{display:none!important}
html[data-nook-ui] .nook-wave-wrap>meter{position:absolute;width:1px!important;height:1px!important;clip-path:inset(50%);overflow:hidden}
html[data-nook-ui] .nook-dot-wave{display:grid;grid-template-columns:repeat(var(--nook-wave-columns,21),2px);gap:3px;align-items:center;justify-content:center;height:27px;color:var(--nook-text)}
html[data-nook-ui] .nook-dot-wave>span{display:grid;grid-template-rows:repeat(7,2px);gap:2px}
html[data-nook-ui] .nook-dot-wave i{width:2px;height:2px;border-radius:50%;background:currentColor;opacity:.07;transition:opacity 90ms linear}
html[data-nook-ui] .nook-dot-wave i[data-on]{opacity:.82}
html[data-nook-ui] .nook-wave-wrap[data-wide]{width:min(420px,100%);height:52px;flex:1}
html[data-nook-ui] .nook-wave-wrap[data-wide] .nook-dot-wave{gap:4px;height:52px}
html[data-nook-ui] .nook-wave-wrap[data-wide] .nook-dot-wave>span{grid-template-rows:repeat(11,2px);gap:3px}
html[data-nook-ui] .nook-dot-wave i[data-accent][data-on]{background:var(--nook-accent)}
html[data-nook-ui][data-nook-contrast="true"] .nook-dot-wave i[data-on]{opacity:1}
html[data-nook-ui][data-nook-reduce-motion="true"] .nook-dot-wave i{transition:none}
@media(prefers-reduced-motion:reduce){.nook-dot-wave i{transition:none!important}}
"""#
    public static let bootstrap = #"""
(()=>{const start=()=>{
 if(!document.documentElement.hasAttribute('data-nook-ui'))return;
 const installed=new WeakSet();
 function upgrade(meter){
  if(installed.has(meter))return;installed.add(meter);
  const wide=meter.getAttribute('data-nook-wave')==='wide',columns=wide?65:21,radius=wide?5:3;
  const wrap=document.createElement('span');wrap.className='nook-wave-wrap';if(wide)wrap.setAttribute('data-wide','');
  const wave=document.createElement('span');wave.className='nook-dot-wave';wave.setAttribute('aria-hidden','true');
  wave.style.setProperty('--nook-wave-columns',String(columns));
  const dots=[];for(let c=0;c<columns;c++){const column=document.createElement('span');for(let r=-radius;r<=radius;r++){const dot=document.createElement('i');if(wide&&Math.abs(c-32)<=3)dot.setAttribute('data-accent','');column.append(dot);dots.push({dot,c,r});}wave.append(column);}
  meter.before(wrap);wrap.append(meter,wave);
  const update=()=>{const raw=Number(meter.value),max=Number(meter.max);const level=Number.isFinite(raw)&&max>0?Math.min(1,Math.max(0,raw/max)):0;wrap.hidden=meter.hidden;for(const {dot,c,r} of dots){const shape=wide?Math.exp(-Math.pow((c-32)/23,2))*(.28+.72*Math.abs(Math.sin(c*.42))):(.15+.85*Math.abs(Math.sin(c*.48)));const rows=Math.round((wide?Math.sqrt(level):level)*radius*shape);dot.toggleAttribute('data-on',Math.abs(r)<=rows);}};
  new MutationObserver(update).observe(meter,{attributes:true,attributeFilter:['value','max','hidden']});update();
 }
 const scan=()=>document.querySelectorAll('meter[data-nook-wave]').forEach(upgrade);scan();
 new MutationObserver(scan).observe(document.body,{childList:true,subtree:true});
};if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();})();
"""#
}
