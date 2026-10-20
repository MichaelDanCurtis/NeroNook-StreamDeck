import Foundation

/// Main-frame presentation bridge. It never touches iframe content, module
/// state, navigation, selection or the module's revision/event contract.
public enum PluginThemeWeb {
    public static func bootstrap(_ context: PluginAppearanceContext, documentID: String = "standalone") throws -> String {
        try context.validate()
        let data = try JSONEncoder().encode(context)
        let seed = String(decoding: data, as: UTF8.self)
        let document = String(decoding: try JSONEncoder().encode(documentID), as: UTF8.self)
        return """
        (() => {
          let current = null; let serial = -1; const documentID = \(document); const listeners = new Set();
          function apply(value, sequence = 0, target = documentID) {
            if (target !== documentID || sequence < serial || !value || value.version !== 1) return;
            serial = sequence;
            if (current && value.surfaceID === current.surfaceID && value.revision < current.revision) return;
            current = Object.freeze(value);
            const paint = () => {
              if (!document.documentElement) return;
              const root = document.documentElement;
              const p = value.theme[value.scheme];
              const names = {onAccent:'on-accent'};
              for (const [key,color] of Object.entries(p)) root.style.setProperty('--nook-'+(names[key]||key), color);
              const style = value.theme.style;
              for (const key of ['cornerRadius','controlRadius']) root.style.setProperty('--nook-'+key.replace(/[A-Z]/g,m=>'-'+m.toLowerCase()), style[key]+'px');
              root.style.setProperty('--nook-spacing-scale', style.spacingScale);
              root.style.setProperty('--nook-card-opacity', value.reduceTransparency ? 1 : style.cardOpacity);
              root.style.setProperty('--nook-shell-opacity', value.reduceTransparency ? 1 : style.shellOpacity);
              root.style.setProperty('--nook-border-width', (value.increasedContrast ? 2 : style.borderWidth)+'px');
              root.style.colorScheme = value.scheme;
              root.dataset.nookScheme=value.scheme; root.dataset.nookTheme=value.theme.id;
              root.dataset.nookTreatment=style.treatment||'soft';
              root.dataset.nookReduceMotion=String(value.reduceMotion);
              root.dataset.nookContrast=String(value.increasedContrast);
              root.dataset.nookReduceTransparency=String(value.reduceTransparency);
              root.style.setProperty('--nook-glass-tint', (value.reduceTransparency ? 100 : style.treatment==='circuit' ? Math.min(58,style.shellOpacity*65) : Math.min(68,Math.max(42,style.shellOpacity*100-38)))+'%');
              if (!document.getElementById('nook-theme-foundation')) {
                const sheet=document.createElement('style'); sheet.id='nook-theme-foundation';
                sheet.textContent='.nook-presence{display:inline-block;width:32px;height:32px;flex:none;border-radius:50%;background:radial-gradient(circle at 30% 25%,#fff 5%,#f6efec 32%,#ddd8e8 63%,#bccfe1 100%);border:1px solid #ffffffb3;box-shadow:0 0 0 3px #cdbb9f15,inset -3px -3px 9px #b6b3c233;position:relative;vertical-align:middle}.nook-presence:after{content:"";position:absolute;inset:-4px -3px;border:1px dotted #b8a58699;border-radius:47% 53% 49% 51%;transform:rotate(-23deg)}h1 .nook-presence{margin-right:8px}.halo.nook-presence{width:48px;height:48px;margin:0 auto 12px}.mark.nook-presence{width:24px;height:24px} html,body{background:var(--nook-background);color:var(--nook-text)}:focus-visible{outline:2px solid var(--nook-focus);outline-offset:3px}html[data-nook-reduce-motion="true"] *,html[data-nook-reduce-motion="true"] *::before,html[data-nook-reduce-motion="true"] *::after{animation:none!important;transition:none!important;scroll-behavior:auto!important}';
                root.appendChild(sheet);
              }
            };
            if (document.documentElement) paint(); else document.addEventListener('DOMContentLoaded',paint,{once:true});
            for (const fn of listeners) { try { fn(current); } catch (_) {} }
          }
          Object.defineProperty(window,'__neroAppearanceReceive',{value:apply});
          Object.defineProperty(window,'__neroAppearanceAPI',{value:Object.freeze({get current(){return current;},onChange(fn){listeners.add(fn);fn(current);return()=>listeners.delete(fn);}})});
          apply(\(seed), 0, documentID);
        })();
        """
    }
}
