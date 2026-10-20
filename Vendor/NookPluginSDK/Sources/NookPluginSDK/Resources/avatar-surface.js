/* Shared full-volume gaze, speech and finite character interaction controller. */
(()=>{
 const selector='.nook-presence',base='nook-view://surface/__nook_sdk__/';
 const styles=['circuit','stardust','origami','pixel','ceramic','liquid-glass','ink','plush','low-poly','art-deco','wireframe','paper-cut','cel','kinetic','bauhaus','micro-led','watercolor','woodcut','monoline','clay','neon-ronin','graffiti-ghost','chrome-drake','holo-phantom','street-runner'].map(x=>'illustration.'+x);
 const members=new Set();let library,appearance=null,pointer=null,gazeFrame=0,gazeAt=0,announced=null,busy=false;
 const reduced=()=>!!appearance?.reduceMotion||matchMedia('(prefers-reduced-motion:reduce)').matches;
 const reactions=()=>appearance?.avatars?.characterReactions!==false&&!appearance?.avatarReactionsSuppressed&&!reduced();
 const persona=el=>el.dataset.nookAvatar==='ember'?'ember':'nero';
 const clamp=x=>Math.max(-1,Math.min(1,Number.isFinite(x)?x:0));
 function load(){return library||(library=new Promise((resolve,reject)=>{if(customElements.get('nook-avatar-model')){resolve();return;}const s=document.createElement('script');s.src=base+'avatar-renderer.js';s.onload=resolve;s.onerror=reject;document.head.append(s);}));}
 function style(el){const id=appearance?.avatars?.[persona(el)+'Style'];return styles.includes(id)?id:'elemental';}
 function palette(item){const id=appearance?.avatars?.[persona(item.element)+'Palette'];return window.__nookAvatarPalettes?.[id]||window.__nookAvatarPalettes?.[appearance?.theme?.id]||window.__nookAvatarPalettes?.['nearly-nothing'];}
 function eligible(item){const r=item.element.getBoundingClientRect();return reactions()&&!busy&&!document.hidden&&item.visible&&item.element.isConnected&&r.width>=80&&!item.element.closest('button,a,input,select');}
 function sound(kind){const handler=window.webkit?.messageHandlers?.neroAvatarReaction;if(!handler)return Promise.resolve({duration:kind==='giggle'?1.1:1.3});return Promise.resolve(handler.postMessage({kind,document:window.__nookAvatarDocument})).catch(()=>({duration:1.3}));}
 function announce(){const enabled=!document.hidden&&!reduced()&&[...members].some(i=>i.visible&&i.element.isConnected);if(enabled===announced)return;announced=enabled;const h=window.webkit?.messageHandlers?.neroAvatarPresence;if(h)Promise.resolve(h.postMessage({active:enabled})).catch(()=>{});}
 function stopReaction(item){item.reactionSerial++;cancelAnimationFrame(item.reactionFrame);item.reactionFrame=0;item.element.dataset.nookReaction='';if(item.caption)item.caption.textContent='';item.reacting=false;item.viewer?.setReaction?.({});item.viewer?.setFace?.({speak:0,laugh:0,smile:0,surprise:0,blink:0});}
 // Same normalized curves as PluginAvatarReactionPose; no indefinite animation.
 function reactionPose(kind,elapsed,duration){if(!Number.isFinite(elapsed)||!Number.isFinite(duration)||duration<=0||elapsed<0||elapsed>=duration)return {x:0,y:0,roll:0,mouth:0,smile:0,laugh:0,surprise:0,blink:0};
  const t=elapsed/duration,fade=Math.min(1,t*12)*Math.min(1,(1-t)*10),wave=Math.sin(t*Math.PI*6),beat=Math.max(0,wave);
  return kind==='giggle'?{x:0,y:beat*.065*fade,roll:wave*.055*fade,mouth:beat*.25*fade,smile:.75*fade,laugh:beat*.7*fade,surprise:0,blink:.65*fade}:{x:wave*.12*fade,y:Math.abs(wave)*.035*fade,roll:-wave*.14*fade,mouth:beat*.45*fade,smile:0,laugh:0,surprise:.7*fade,blink:0};
 }
 function react(item,kind){if(!eligible(item)||performance.now()-item.lastReaction<1000)return;for(const other of members)stopReaction(other);item.lastReaction=performance.now();item.reacting=true;const serial=++item.reactionSerial;item.element.dataset.nookReaction=kind;item.caption.textContent=kind==='giggle'?'Hehehe!':'Zoom, zoom, zoom!';
  sound(kind).then(reply=>{if(serial!==item.reactionSerial)return;if(!eligible(item)){stopReaction(item);return;}const start=performance.now(),duration=Math.min(3,Math.max(.3,Number(reply.duration)||1.3));
   function step(now){if(serial!==item.reactionSerial)return;if(!eligible(item)){stopReaction(item);sound('stop');return;}const elapsed=(now-start)/1000,p=reactionPose(kind,elapsed,duration);if(Array.isArray(reply.levels)&&reply.levels.length<=150&&reply.step===.02){const amplitude=Number(reply.levels[Math.floor(elapsed/.02)])||0;p.mouth=amplitude*.65;p.laugh=kind==='giggle'?amplitude*.55:0;p.surprise=kind==='zoom'?amplitude*.65:0;}item.viewer?.setReaction?.(p);item.viewer?.setFace?.({speak:p.mouth,laugh:p.laugh,smile:p.smile,surprise:p.surprise,blink:p.blink});if(elapsed<duration)item.reactionFrame=requestAnimationFrame(step);else{stopReaction(item);mouth(item);}}
   item.reactionFrame=requestAnimationFrame(step);
  });
 }
 function gesture(item,sample,now){const rect=item.element.getBoundingClientRect(),near=sample&&Math.hypot(sample.x-rect.left-rect.width/2,sample.y-rect.top-rect.height/2)<Math.max(100,rect.width*1.2);const g=item.gesture;
  if(!near||!eligible(item)){g.previous=null;g.velocity=null;g.turns=0;return;}
  const p=g.previous;g.previous={x:sample.x,y:sample.y,time:now};if(!p)return;const dt=(now-p.time)/1000;if(dt<.012||dt>.25){g.velocity=null;g.turns=0;return;}
  const dx=(sample.x-p.x)/dt,dy=(sample.y-p.y)/dt,speed=Math.hypot(dx,dy);if(speed<900||now-g.cooldown<6000){g.velocity=null;g.turns=0;return;}const v={x:dx/speed,y:dy/speed};
  if(g.velocity&&g.velocity.x*v.x+g.velocity.y*v.y<.4){if(!g.turns||now-g.firstTurn>800){g.firstTurn=now;g.turns=0;}g.turns++;}g.velocity=v;
  if(g.turns>=2){g.cooldown=now;g.turns=0;g.velocity=null;react(item,'zoom');}
 }
 function gazeTick(now){gazeFrame=0;const alpha=1-Math.exp(-Math.min(50,Math.max(8,now-gazeAt))/65);gazeAt=now;let moving=false;
  for(const item of members){if(document.hidden||reduced()||!item.visible||!item.element.isConnected){item.gaze={x:0,y:0};item.viewer?.setGaze?.(0,0);continue;}
   const r=item.element.getBoundingClientRect();const x=pointer?clamp((pointer.x-r.left-r.width/2)/Math.max(100,r.width*1.5)):0,y=pointer?clamp((r.top+r.height/2-pointer.y)/Math.max(90,r.height*1.5)):0;const dx=x-item.gaze.x,dy=y-item.gaze.y,settled=Math.abs(dx)<.002&&Math.abs(dy)<.002;
   item.gaze=settled?{x,y}:{x:item.gaze.x+dx*alpha,y:item.gaze.y+dy*alpha};item.viewer?.setGaze?.(item.gaze.x,item.gaze.y);moving||=!settled;
  }if(moving)gazeFrame=requestAnimationFrame(gazeTick);
 }
 function track(sample){pointer=sample&&['x','y','rangeX','rangeY'].every(k=>Number.isFinite(sample[k]))&&sample.rangeX>0&&sample.rangeY>0?sample:null;
  for(const item of members)gesture(item,pointer,performance.now());
  if(document.hidden||reduced()){cancelAnimationFrame(gazeFrame);gazeFrame=0;for(const i of members){i.gaze={x:0,y:0};i.viewer?.setGaze?.(0,0);}return;}
  if(!gazeFrame){gazeAt=performance.now();gazeFrame=requestAnimationFrame(gazeTick);}
 }
 function mouth(item){if(!item.viewer?.loaded)return;const active=item.element.dataset.nookSpeaking==='true';if(active&&item.reacting){stopReaction(item);sound('stop');}if(item.reacting)return;
  const raw=Number(item.element.dataset.nookSpeechLevel||0);const level=active&&!document.hidden&&!reduced()&&item.visible&&Number.isFinite(raw)?Math.sqrt(Math.min(1,Math.max(0,raw)*8)):0;item.viewer.setFace({speak:level,laugh:0,smile:0,surprise:0,blink:0});
 }
 function expression(item){const a=(item.element.dataset.nookExpression||'0,0,0').split(',').map(Number),enabled=!reduced()&&!document.hidden&&item.visible&&a.length===3&&a.every(Number.isFinite);item.viewer?.setPosture?.(enabled?{pitch:Math.min(5,Math.max(-5,a[0])),roll:Math.min(6,Math.max(-6,a[1])),lift:Math.min(.03,Math.max(-.03,a[2]))}:{pitch:0,roll:0,lift:0});}
 function paint(item){if(item.style==='elemental')item.viewer?.applyPalette?.(palette(item)?.avatars[persona(item.element)],persona(item.element));}
 function assign(item,next,source){item.style=next;item.sourceSerial++;item.viewer.src=source;}
 function select(item,next){const serial=++item.assetSerial;item.requestedStyle=next;stopReaction(item);assign(item,'elemental',window.__nookAvatarModels[persona(item.element)]);if(next==='elemental')return;
  const p=persona(item.element),handler=window.webkit?.messageHandlers?.neroAvatarModel;
  if(!handler)return;Promise.resolve(handler.postMessage({style:next,persona:p,document:window.__nookAvatarDocument})).then(reply=>{if(!item.element.isConnected||!members.has(item)||serial!==item.assetSerial)return;if(reply?.style!==next||reply?.persona!==p||typeof reply.source!=='string'||reply.source.length>2796240||!/^data:model\/gltf-binary;base64,[A-Za-z0-9+/]+={0,2}$/.test(reply.source))return;assign(item,next,reply.source);}).catch(()=>{});
 }
 function configure(item){const enabled=eligible(item);item.element.dataset.nookInteractive=String(enabled);if(enabled){item.element.removeAttribute('aria-hidden');item.element.setAttribute('role','button');item.element.setAttribute('aria-label','Play with '+persona(item.element));item.element.tabIndex=0;}else{item.element.removeAttribute('role');item.element.removeAttribute('tabindex');item.element.setAttribute('aria-hidden','true');}}
 function sync(item){if(item.viewer&&style(item.element)!==item.requestedStyle)select(item,style(item.element));paint(item);expression(item);mouth(item);configure(item);if(!reactions()||busy||document.hidden){stopReaction(item);sound('stop');}}
 const observer=new IntersectionObserver(entries=>{for(const e of entries){const item=[...members].find(i=>i.element===e.target);if(item){item.visible=e.isIntersecting;item.viewer?.setVisible?.(e.isIntersecting);if(!item.visible)stopReaction(item);sync(item);}}announce();track(pointer);});
 function attach(el){if(el.dataset.nookAvatarMounted)return;el.dataset.nookAvatarMounted='true';const item={element:el,viewer:null,visible:true,gaze:{x:0,y:0},assetSerial:0,sourceSerial:0,requestedStyle:null,reactionSerial:0,reactionFrame:0,lastReaction:-Infinity,gesture:{previous:null,velocity:null,turns:0,firstTurn:0,cooldown:-Infinity}};members.add(item);
  load().then(()=>{if(!el.isConnected){members.delete(item);return;}const v=document.createElement('nook-avatar-model');item.viewer=v;v.setAttribute('aria-hidden','true');
   v.addEventListener('load',()=>{paint(item);expression(item);mouth(item);v.setGaze(item.gaze.x,item.gaze.y);});
   v.addEventListener('error',()=>{if(item.style!=='elemental'){assign(item,'elemental',window.__nookAvatarModels[persona(el)]);}else{v.remove();el.style.backgroundImage='url('+base+'elemental-01-'+persona(el)+'.png)';el.style.backgroundSize='contain';}});
   item.caption=document.createElement('span');item.caption.className='nook-avatar-caption';item.caption.setAttribute('aria-hidden','true');el.replaceChildren(v,item.caption);el.addEventListener('click',()=>react(item,'giggle'));el.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();react(item,'giggle');}});observer.observe(el);sync(item);
  }).catch(()=>{el.style.backgroundImage='url('+base+'elemental-01-'+persona(el)+'.png)';el.style.backgroundSize='contain';});
 }
 function scan(){document.querySelectorAll(selector).forEach(attach);for(const item of members)if(!item.element.isConnected){item.assetSerial++;stopReaction(item);observer.unobserve(item.element);members.delete(item);}if(!members.size){cancelAnimationFrame(gazeFrame);gazeFrame=0;sound('stop');}announce();}
 const mutations=new MutationObserver(entries=>{if(entries.some(e=>e.type==='childList'))scan();for(const e of entries){const item=[...members].find(i=>i.element===e.target);if(item){mouth(item);expression(item);}}});mutations.observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['data-nook-speech-level','data-nook-speaking','data-nook-expression']});
 document.addEventListener('visibilitychange',()=>{for(const i of members){i.viewer?.setVisible?.(!document.hidden&&i.visible);sync(i);}if(document.hidden)sound('stop');announce();track(document.hidden?null:pointer);});
 document.addEventListener('keydown',e=>{if(e.key==='Escape'){members.forEach(stopReaction);sound('stop');}});
 window.addEventListener('pointermove',e=>{if(!window.webkit?.messageHandlers?.neroAvatarPresence)track({x:e.clientX,y:e.clientY,rangeX:innerWidth*.28,rangeY:innerHeight*.28});},{passive:true});
 window.NookAvatar=Object.freeze({
  speech(el,level,speaking){el.dataset.nookSpeechLevel=String(Number.isFinite(level)?Math.max(0,Math.min(1,level)):0);el.dataset.nookSpeaking=String(!!speaking);const i=[...members].find(i=>i.element===el);if(i)mouth(i);},
  expression(el,p={}){el.dataset.nookExpression=[p.pitch||0,p.roll||0,p.lift||0].join(',');const i=[...members].find(i=>i.element===el);if(i)expression(i);},
  pointer:track,
  setBusy(value){if(busy===!!value)return;busy=!!value;for(const item of members)sync(item);if(busy)sound('stop');},
  stop(){for(const i of members){stopReaction(i);i.viewer?.setFace?.({speak:0,laugh:0,smile:0,surprise:0,blink:0});}sound('stop');},
  reactionPose,
  get wantsPointer(){return !document.hidden&&!reduced()&&[...members].some(i=>i.visible&&i.element.isConnected);},
  get status(){return {members:members.size,busy,following:announced};}
 });
 if(window.__neroAppearanceAPI)window.__neroAppearanceAPI.onChange(value=>{appearance=value;for(const item of members)sync(item);announce();track(pointer);});
 scan();
})();
