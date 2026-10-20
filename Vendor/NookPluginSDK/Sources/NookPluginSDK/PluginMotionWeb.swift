import Foundation

public enum PluginMotionWeb {
    /// Local presentation only: no business messages, timers, network or input.
    /// New view surfaces emerge once; streamed text and transcript rows do not.
    public static let bootstrap = #"""
    (() => {
      const start=()=>{
        if(!document.documentElement.hasAttribute('data-nook-ui')) return;
        const root=document.documentElement, seen=new WeakSet(), active=new Set();
        const preference=window.matchMedia('(prefers-reduced-motion: reduce)');
        const reduced=()=>preference.matches||root.dataset.nookReduceMotion==='true';
        const cancel=()=>{for(const a of active)a.cancel();active.clear();};
        let order=0;
        const reveal=element=>{
          if(!element||reduced()||document.hidden||!element.animate||element.hidden) return;
          const index=order++, from=index%2===0?'inset(0 100% 0 0)':'inset(0 0 0 100%)';
          const a=element.animate([{clipPath:from},{clipPath:'inset(0 -8px 0 -8px)'}],{duration:280,delay:(index%6)*45,fill:'backwards',easing:'cubic-bezier(.2,.7,.2,1)'});
          active.add(a);a.onfinish=a.oncancel=()=>active.delete(a);
        };
        const transient='input,textarea,select,option,#transcript,#liveLines,#livePartials,#messages,#chatHistory,#library,#speakers,#marks,[role="log"],[aria-live]';
        const meaningful=element=>element.matches?.('button,details,.nook-reading-card,[data-nook-reveal]')&&!element.closest(transient);
        const remember=element=>{seen.add(element);element.querySelectorAll?.('button,details,.nook-reading-card,[data-nook-reveal]').forEach(e=>seen.add(e));};
        // Reveal stable pieces, never the entire document. Keep each batch bounded.
        const pieces=document.body.querySelectorAll('header,footer,aside,.compose,.talkBar,.nook-reading-card,[data-nook-reveal]');
        let initial=Array.from(pieces).filter(e=>!e.closest(transient)&&!e.hidden);
        // Nested surfaces belong to their nearest selected parent, avoiding double masks.
        initial=initial.filter(e=>!initial.some(parent=>parent!==e&&parent.contains?.(e)));
        if(!initial.length) initial=Array.from(document.body.querySelectorAll('button,details')).filter(meaningful);
        initial.slice(0,18).forEach(reveal);remember(document.body);
        const observer=new MutationObserver(records=>{
          for(const record of records){
            if(record.type==='attributes'){
              if(record.target===root){if(reduced())cancel();continue;}
              // Only an actual hidden→visible transition; repeated state writes do not replay.
              if(record.oldValue!==null&&!record.target.hidden&&!record.target.closest(transient))reveal(record.target);
            } else for(const element of record.addedNodes){
              if(element.nodeType!==1||seen.has(element))continue;
              if(meaningful(element)){reveal(element);remember(element);}
              else element.querySelectorAll?.('button,details,[data-nook-reveal]').forEach(e=>{if(!seen.has(e)&&meaningful(e)){reveal(e);seen.add(e);}});
            }
          }
        });
        observer.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['hidden'],attributeOldValue:true});
        const appearanceObserver=new MutationObserver(()=>{if(reduced())cancel();});
        appearanceObserver.observe(root,{attributes:true,attributeFilter:['data-nook-reduce-motion']});
        const visibility=()=>{root.dataset.nookDocumentHidden=String(document.hidden);if(document.hidden)cancel();};
        document.addEventListener('visibilitychange',visibility);visibility();
        preference.addEventListener('change',()=>{if(reduced())cancel();});
        window.addEventListener('pagehide',()=>{observer.disconnect();appearanceObserver.disconnect();cancel();},{once:true});
      };
      if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
    })();
    """#
}
