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
.nook-presence nook-avatar-model{display:block;width:100%;height:100%;background:transparent;--poster-color:transparent;--progress-bar-height:0px;--progress-bar-color:transparent;pointer-events:none}
"""#
    public static let bootstrap = #"""
(() => {
 const selector='.nook-presence', base='nook-view://surface/__nook_sdk__/';
 const styles=["illustration.monoline"];
 let library=null; const members=new Set(); let appearance=null;
 let pointer=null,gazeFrame=0,gazeAt=0,announced=null;
 const reduced=()=>!!appearance?.reduceMotion||matchMedia('(prefers-reduced-motion:reduce)').matches;
 const weight=(x,active)=>active&&Number.isFinite(x)?Math.min(1,Math.max(0,x)):0;
 const mouthWeight=(x,active)=>Math.sqrt(Math.min(1,weight(x,active)*8));
 const time=w=>w<=.7?w/7:.2+(w-.3)/7;
 function load(){return library||(library=new Promise((resolve,reject)=>{
   if(customElements.get('nook-avatar-model')){resolve();return;}
   const s=document.createElement('script');s.src=base+'elemental-model-viewer.js';s.onload=resolve;s.onerror=reject;document.head.append(s);
 }));}
 function persona(el){return el.dataset.nookAvatar==='ember'?'ember':'nero';}
 function style(el){const value=appearance?.avatars?.[persona(el)+'Style'];return styles.includes(value)?value:'elemental';}
 function palette(item){const id=appearance?.avatars?.[persona(item.element)+'Palette'];return window.__nookAvatarPalettes?.[id]|| window.__nookAvatarPalettes?.[appearance?.theme?.id]||window.__nookAvatarPalettes?.['nearly-nothing'];}
 function rgba(hex){return [1,3,5].map(i=>parseInt(hex.slice(i,i+2),16)/255).concat(1);}
 function gazePose(item){
   const v=item.viewer;if(!item.ready||!v?.loaded)return;
   const {x,y}=item.gaze,stamp=x.toFixed(3)+','+y.toFixed(3);if(stamp===item.gazeStamp)return;item.gazeStamp=stamp;
   const bodyX=Math.sin(x*Math.PI/2),bodyY=Math.sin(y*Math.PI/2);
   v.orientation=`${(-bodyX*4).toFixed(3)}deg ${(-bodyY*16).toFixed(3)}deg ${(bodyX*26).toFixed(3)}deg`;
   // Translate the decorative viewer, not its hit target. Its unchanged outer
   // bounds keep pointer direction stable rather than chasing the moving body.
   v.style.transform=`translate3d(${(bodyX*3.5).toFixed(3)}%,${(-bodyY*2.25).toFixed(3)}%,0)`;
   // Constant eye translation clips blend with the original pose. They share
   // neither morph channels nor time progression with the spoken-mouth clip.
   if(typeof v.appendAnimation==='function'&&v.availableAnimations?.includes('LookLeft')){
     const t=v.currentTime;
     for(const [name,w] of [['LookLeft',Math.max(0,-x)/2],['LookRight',Math.max(0,x)/2],['LookUp',Math.max(0,y)/2],['LookDown',Math.max(0,-y)/2]])
       v.appendAnimation(name,{weight:w,timeScale:0,time:0,fade:false});
     v.pause();v.currentTime=t;
   }
 }
 function resetGaze(item){item.gaze={x:0,y:0};gazePose(item);}
 function announce(){
   const enabled=!document.hidden&&!reduced()&&[...members].some(i=>i.visible&&i.element.isConnected);
   if(enabled===announced)return;announced=enabled;
   const handler=window.webkit?.messageHandlers?.neroAvatarPresence;
   if(handler)Promise.resolve(handler.postMessage({active:enabled})).catch(()=>{});
 }
 function gazeTick(now){
   gazeFrame=0;const alpha=1-Math.exp(-Math.min(50,Math.max(8,now-gazeAt))/85);gazeAt=now;let moving=false;
   for(const item of members){
     if(document.hidden||reduced()||!item.visible||!item.element.isConnected){resetGaze(item);continue;}
     const rect=item.element.getBoundingClientRect();let x=0,y=0;
     if(pointer&&rect.width>0&&rect.height>0){x=Math.min(1,Math.max(-1,(pointer.x-rect.left-rect.width/2)/pointer.rangeX));y=Math.min(1,Math.max(-1,(rect.top+rect.height/2-pointer.y)/pointer.rangeY));}
     const old=item.gaze,dx=x-old.x,dy=y-old.y;
     const settled=Math.abs(dx)<.002&&Math.abs(dy)<.002;
     item.gaze=settled?{x,y}:{x:old.x+dx*alpha,y:old.y+dy*alpha};gazePose(item);moving ||= !settled;
   }
   if(moving)gazeFrame=requestAnimationFrame(gazeTick);
 }
 function track(sample){
   pointer=sample&&['x','y','rangeX','rangeY'].every(k=>Number.isFinite(sample[k]))&&sample.rangeX>0&&sample.rangeY>0?sample:null;
   if(document.hidden||reduced()){cancelAnimationFrame(gazeFrame);gazeFrame=0;members.forEach(resetGaze);return;}
   if(!gazeFrame){gazeAt=performance.now();gazeFrame=requestAnimationFrame(gazeTick);}
 }
 async function paint(item){
   const p=palette(item),v=item.viewer;if(!item.element.isConnected||item.style!=='elemental'||!p||!v?.loaded||!v.model)return;
   const stamp=++item.stamp, colors=p.avatars[persona(item.element)];
   for(const m of v.model.materials){
     const name=m.name.toLowerCase(), face=name.includes('face'), inner=name.includes('inner');
     if(persona(item.element)==='ember'&&!face){
       const c=document.createElement('canvas');c.width=8;c.height=256;const x=c.getContext('2d');
       const g=x.createLinearGradient(0,256,0,0);g.addColorStop(0,colors.base);g.addColorStop(.4,colors.body);g.addColorStop(1,colors.tip);x.fillStyle=g;x.fillRect(0,0,8,256);
       const texture=await v.createTexture(c.toDataURL());if(stamp!==item.stamp||!item.element.isConnected||item.viewer!==v)return;
       m.pbrMetallicRoughness.baseColorTexture.setTexture(texture);m.pbrMetallicRoughness.setBaseColorFactor([1,1,1,1]);
       m.emissiveTexture.setTexture(texture);m.setEmissiveFactor([.18,.18,.18]);
     } else {m.pbrMetallicRoughness.setBaseColorFactor(rgba(colors[face?'face':inner?'core':'body']));}
     m.pbrMetallicRoughness.setRoughnessFactor(.48);
   }
 }
 async function mouth(item){
   const v=item.viewer;if(!item.element.isConnected||!v?.loaded)return;
   if(v.animationName!=='Speak'){v.animationCrossfadeDuration=0;v.animationName='Speak';await v.updateComplete;}
   if(item.viewer!==v||!item.element.isConnected||!v.loaded)return;
   // Read the latest state after async viewer setup. Stop/visibility changes
   // during that await must win over an older speaking update.
   const active=item.element.dataset.nookSpeaking==='true';
   const reduced=appearance?.reduceMotion||matchMedia('(prefers-reduced-motion:reduce)').matches;
   const value=mouthWeight(Number(item.element.dataset.nookSpeechLevel||0),active&&!reduced&&!document.hidden&&item.visible);
   cancelAnimationFrame(item.frame);v.pause();
   if(value===0){item.level=0;v.currentTime=0;return;}
   const from=item.level,start=performance.now();
   function step(now){
     const t=Math.min(1,Math.max(0,(now-start)/90));item.level=from+(value-from)*t;v.currentTime=time(item.level);
     if(t<1)item.frame=requestAnimationFrame(step);
   }
   item.frame=requestAnimationFrame(step);
 }
 function scene(item){
   const value=appearance?.seasonalScene,el=item.element;
   el.dataset.nookSeason=!value||appearance?.increasedContrast||appearance?.reduceTransparency||el.getBoundingClientRect().width<80?'':value.holiday==='christmas'?'🌲'+(value.day>=2?' 🎁':'')+(value.day>=3?' ✦':'')+(value.day>=4?' ·':''):value.holiday==='thanksgiving'?'🍂'+(value.day>=3?' 🦃':''):'🎃'+(value.day>=3?' ☾':'');
 }
 function camera(item){item.viewer.setAttribute('camera-orbit',item.style==='illustration.monoline'?'0deg 90deg 4m':'15deg 77deg auto');}
 function sync(item){
   scene(item);const next=style(item.element);
   if(item.viewer&&next!==item.style){item.style=next;item.ready=false;item.gazeStamp='';camera(item);item.viewer.src=next==='elemental'?window.__nookAvatarModels[persona(item.element)]:base+'avatar-'+next.slice(13)+'-'+persona(item.element)+'.glb';}
 }
 function attach(el){
   if(el.dataset.nookAvatarMounted)return;el.dataset.nookAvatarMounted='true';
   // The span remains decorative. Its owner supplies accessible status text.
   const item={element:el,viewer:null,stamp:0,visible:true,level:0,frame:0,ready:false,gaze:{x:0,y:0},gazeStamp:''};members.add(item);
   load().then(()=>{
     if(!el.isConnected){members.delete(item);return;}
     const p=persona(el),v=document.createElement('nook-avatar-model');item.viewer=v;
     v.setAttribute('aria-hidden','true');v.setAttribute('loading','eager');v.setAttribute('reveal','auto');v.setAttribute('interaction-prompt','none');
     v.setAttribute('environment-image','neutral');v.setAttribute('shadow-intensity','0');v.setAttribute('exposure','.9');v.setAttribute('camera-orbit','15deg 77deg auto');
     v.setAttribute('poster',base+'elemental-'+String(palette(item)?.index||1).padStart(2,'0')+'-'+p+'.png');
     item.style=style(el);camera(item);v.src=item.style==='elemental'?window.__nookAvatarModels[p]:base+'avatar-'+item.style.slice(13)+'-'+p+'.glb';v.addEventListener('load',async()=>{paint(item);await mouth(item);if(!el.isConnected)return;item.ready=true;gazePose(item);track(pointer);});
     v.addEventListener('error',()=>{v.remove();el.style.setProperty('background-image','url('+base+'elemental-01-'+p+'.png)','important');el.style.backgroundSize='contain';});
     el.replaceChildren(v);scene(item);observer.observe(el);
   }).catch(()=>{el.style.setProperty('background-image','url('+base+'elemental-01-'+persona(el)+'.png)','important');el.style.backgroundSize='contain';});
 }
 const observer=new IntersectionObserver(entries=>{for(const e of entries){const item=[...members].find(i=>i.element===e.target);if(item){item.visible=e.isIntersecting;mouth(item);if(!item.visible)resetGaze(item);}}announce();track(pointer);});
 function scan(){document.querySelectorAll(selector).forEach(attach);for(const item of members)if(!item.element.isConnected){cancelAnimationFrame(item.frame);observer.unobserve(item.element);members.delete(item);}if(!members.size){cancelAnimationFrame(gazeFrame);gazeFrame=0;}announce();}
 const changes=new MutationObserver(entries=>{if(entries.some(e=>e.type==='childList'))scan();for(const e of entries){const item=[...members].find(i=>i.element===e.target);if(item)mouth(item);}});
 changes.observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['data-nook-speech-level','data-nook-speaking']});
 document.addEventListener('visibilitychange',()=>{members.forEach(mouth);announce();track(document.hidden?null:pointer);});
 window.__neroAppearanceAPI?.onChange(value=>{appearance=value;members.forEach(i=>{sync(i);paint(i);mouth(i);});announce();track(pointer);});
 Object.defineProperty(window,'NookAvatar',{value:Object.freeze({get wantsPointer(){return !document.hidden&&!reduced()&&[...members].some(i=>i.visible);},pointer:track,speech(element,level,speaking){
   if(!element)return;element.dataset.nookSpeaking=String(!!speaking);element.dataset.nookSpeechLevel=String(weight(level,!!speaking));
 }})});
 // Old/standalone web hosts still get in-window tracking. The native adapter
 // supplies screen-wide relative coordinates when present; never both sources.
 if(!window.webkit?.messageHandlers?.neroAvatarPresence)window.addEventListener?.('pointermove',e=>track({x:e.clientX,y:e.clientY,rangeX:Math.max(160,window.innerWidth*.65),rangeY:Math.max(120,window.innerHeight*.65)}),{passive:true});
 scan();
})();
"""#
}
