/* Shared full-volume gaze, speech and finite character interaction controller. */
(()=>{
 const selector='.nook-presence',base='nook-view://surface/__nook_sdk__/';
 const styles=['circuit','stardust','origami','pixel','ceramic','liquid-glass','ink','plush','low-poly','art-deco','wireframe','paper-cut','cel','kinetic','bauhaus','micro-led','watercolor','woodcut','monoline','clay','neon-ronin','graffiti-ghost','chrome-drake','holo-phantom','street-runner'].map(x=>'illustration.'+x);
 const members=new Set();let library,appearance=null,pointer=null,gazeFrame=0,gazeAt=0,announced=null,busy=false,activeMenu=null,latestPlayback=null;
 const captions={giggle:"He he, that tickles!",zoom:"Zoom, zoom, zoom!",wave:"Hi there!",twirl:"Ta-da!"},titles={giggle:"Tickle",zoom:"Playful Zoom",wave:"Wave hello",twirl:"Happy twirl"};
 const audible=kind=>kind==='giggle'||kind==='zoom';
 const reduced=()=>!!appearance?.reduceMotion||matchMedia('(prefers-reduced-motion:reduce)').matches;
 const reactions=()=>appearance?.avatars?.characterReactions!==false&&!appearance?.avatarReactionsSuppressed&&!reduced();
 const persona=el=>el.dataset.nookAvatar==='ember'?'ember':'nero';
 const clamp=x=>Math.max(-1,Math.min(1,Number.isFinite(x)?x:0));
 function load(){return library||(library=new Promise((resolve,reject)=>{if(customElements.get('nook-avatar-model')){resolve();return;}const s=document.createElement('script');s.src=base+'avatar-renderer.js';s.onload=resolve;s.onerror=reject;document.head.append(s);}));}
 function style(el){const id=appearance?.avatars?.[persona(el)+'Style'];return styles.includes(id)?id:'elemental';}
 function palette(item){const id=appearance?.avatars?.[persona(item.element)+'Palette'];return window.__nookAvatarPalettes?.[id]||window.__nookAvatarPalettes?.[appearance?.theme?.id]||window.__nookAvatarPalettes?.['nearly-nothing'];}
 function eligible(item){const r=item.element.getBoundingClientRect();return reactions()&&!busy&&![...members].some(i=>i.element.dataset.nookSpeaking==='true')&&!document.hidden&&item.visible&&item.element.isConnected&&r.width>=80&&!item.element.closest('button,a,input,select');}
 function sound(kind){const handler=window.webkit?.messageHandlers?.neroAvatarReaction;if(!handler)return Promise.resolve({duration:kind==='giggle'?1.1:1.3});return Promise.resolve(handler.postMessage({kind,document:window.__nookAvatarDocument})).catch(()=>({duration:1.3}));}
 function announce(){const enabled=!document.hidden&&!reduced()&&[...members].some(i=>i.visible&&i.element.isConnected);if(enabled===announced)return;announced=enabled;const h=window.webkit?.messageHandlers?.neroAvatarPresence;if(h)Promise.resolve(h.postMessage({active:enabled})).catch(()=>{});}
 function stopReaction(item){item.delegated=null;item.receivedPlayback=false;item.reactionSerial++;cancelAnimationFrame(item.reactionFrame);item.reactionFrame=0;item.element.dataset.nookReaction='';if(item.caption)item.caption.textContent='';item.reacting=false;item.viewer?.setReaction?.({});item.viewer?.setFace?.({speak:0,laugh:0,smile:0,surprise:0,blink:0});}
 // Same normalized curves as PluginAvatarReactionPose; no indefinite animation.
 function reactionPose(kind,elapsed,duration){if(!Number.isFinite(elapsed)||!Number.isFinite(duration)||duration<=0||elapsed<0||elapsed>=duration)return {x:0,y:0,roll:0,turn:0,wave:0,mouth:0,smile:0,laugh:0,surprise:0,blink:0};
  const t=elapsed/duration,fade=Math.min(1,t*12)*Math.min(1,(1-t)*10),wave=Math.sin(t*Math.PI*6),beat=Math.max(0,wave),p={x:0,y:0,roll:0,turn:0,wave:0,mouth:0,smile:0,laugh:0,surprise:0,blink:0};
  if(kind==='giggle'){p.y=beat*.045*fade;p.roll=wave*.055*fade;p.smile=.85*fade;p.laugh=beat*.35*fade;p.blink=.45*fade;}
  else if(kind==='zoom'){p.x=wave*.14*fade;p.y=Math.abs(wave)*.06*fade;p.roll=-wave*.16*fade;p.smile=.9*fade;p.laugh=beat*.42*fade;p.blink=.3*fade;}
  else if(kind==='wave'){p.wave=fade*(.7+wave*.3);p.roll=wave*.065*fade;p.y=beat*.025*fade;p.smile=.7*fade;p.blink=Math.max(0,Math.sin(t*Math.PI*2))*.3*fade;}
  else if(kind==='twirl'){p.turn=2*Math.PI*t*t*(3-2*t);p.y=Math.sin(t*Math.PI)*.10;p.roll=Math.sin(t*Math.PI*2)*.08*fade;p.wave=.5*fade;p.smile=.85*fade;}
  return p;
 }
 function playback(value){
  const valid=value&&typeof value.id==='string'&&/^[0-9a-f-]{36}$/i.test(value.id)&&['giggle','zoom'].includes(value.kind)&&['preparing','speaking'].includes(value.speech?.phase)&&Number.isFinite(value.speech?.level)&&value.speech.level>=0&&value.speech.level<=1;
  latestPlayback=valid?{...value,at:performance.now()}:null;
  for(const item of members){if(!item.delegated)continue;if(latestPlayback?.id===item.delegated){item.receivedPlayback=true;if(latestPlayback.speech.phase==='speaking'&&!item.playbackStarted)item.playbackStarted=performance.now();}
   else if(!latestPlayback&&item.receivedPlayback){stopReaction(item);mouth(item);}}
 }
 function react(item,kind){if(!titles[kind]||!eligible(item)||performance.now()-item.lastReaction<1000)return;closeMenu();for(const other of members)stopReaction(other);sound('stop');item.lastReaction=performance.now();item.reacting=true;const serial=++item.reactionSerial;item.element.dataset.nookReaction=kind;item.caption.textContent=captions[kind];
  const reply=audible(kind)?sound(kind):Promise.resolve({duration:kind==='wave'?1.6:1.8});
  reply.then(reply=>{if(serial!==item.reactionSerial)return;if(!eligible(item)){stopReaction(item);sound('stop');return;}const start=performance.now(),duration=Math.min(6,Math.max(.3,Number(reply.duration)||3));
   item.delegated=reply.delegated===true&&typeof reply.id==='string'?reply.id:null;item.playbackStarted=0;item.receivedPlayback=false;item.lastPoseAt=-Infinity;item.lastPose=null;if(item.delegated&&latestPlayback?.id===item.delegated)playback(latestPlayback);
   function step(now){if(serial!==item.reactionSerial)return;if(!eligible(item)){stopReaction(item);sound('stop');return;}
    let elapsed=(now-start)/1000,p;
    if(item.delegated){
     if(elapsed>45){stopReaction(item);sound('stop');return;}
     const sample=latestPlayback?.id===item.delegated?latestPlayback:null,speaking=sample?.speech.phase==='speaking',fresh=sample&&now-sample.at<500;
     p=speaking?reactionPose(kind,((now-item.playbackStarted)/1000)%3,3):reactionPose(kind,.3,3);
     const amplitude=speaking&&fresh?Math.sqrt(sample.speech.level):0;p.mouth=amplitude*.60;p.laugh=amplitude*(kind==='giggle'?.24:.35);p.surprise=0;
    }else{p=reactionPose(kind,elapsed,duration);if(audible(kind)){p.mouth=0;p.laugh=0;}}
    const encoded=JSON.stringify(p);if(now-item.lastPoseAt>=1000/24&&encoded!==item.lastPose){item.lastPoseAt=now;item.lastPose=encoded;item.viewer?.setReaction?.(p);item.viewer?.setFace?.({speak:p.mouth,laugh:p.laugh,smile:p.smile,surprise:p.surprise,blink:p.blink});}if(item.delegated||elapsed<duration)item.reactionFrame=requestAnimationFrame(step);else{stopReaction(item);mouth(item);}}
   item.reactionFrame=requestAnimationFrame(step);
  });
 }

 function closeMenu(){if(activeMenu){activeMenu.node.remove();activeMenu.item.element.setAttribute('aria-expanded','false');activeMenu=null;}}
 function openMenu(item){if(!eligible(item))return;closeMenu();const menu=document.createElement('div');menu.className='nook-avatar-menu';menu.setAttribute('role','menu');menu.setAttribute('aria-label','Play with '+persona(item.element));
  for(const [kind,title] of [...Object.entries(titles),['stop','Stop']]){const button=document.createElement('button');button.type='button';button.textContent=title;button.setAttribute('role','menuitem');button.addEventListener('click',()=>{closeMenu();if(kind==='stop'){members.forEach(stopReaction);sound('stop');}else react(item,kind);});menu.append(button);}
  const rect=item.element.getBoundingClientRect();menu.style.left=Math.max(8,Math.min(innerWidth-196,rect.left+rect.width/2-90))+'px';menu.style.top=Math.max(8,Math.min(innerHeight-220,rect.bottom+8))+'px';document.body.append(menu);activeMenu={node:menu,item};item.element.setAttribute('aria-expanded','true');menu.children[0]?.focus?.();
  menu.addEventListener('keydown',e=>{const buttons=[...menu.children],index=buttons.indexOf(document.activeElement);if(e.key==='ArrowDown'||e.key==='ArrowUp'){e.preventDefault();buttons[(index+(e.key==='ArrowDown'?1:buttons.length-1))%buttons.length]?.focus?.();}});
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
 function configure(item){const enabled=eligible(item);item.element.dataset.nookInteractive=String(enabled);if(enabled){item.element.removeAttribute('aria-hidden');item.element.setAttribute('role','button');item.element.setAttribute('aria-haspopup','menu');item.element.setAttribute('title','Click to tickle · Right-click for more');item.element.setAttribute('aria-label','Play with '+persona(item.element));item.element.tabIndex=0;}else{item.element.removeAttribute('role');item.element.removeAttribute('tabindex');item.element.setAttribute('aria-hidden','true');}}
 function sync(item){if(item.viewer&&style(item.element)!==item.requestedStyle)select(item,style(item.element));paint(item);expression(item);mouth(item);configure(item);if(!reactions()||busy||document.hidden){if(activeMenu?.item===item)closeMenu();stopReaction(item);sound('stop');}if(appearance?.avatars?.reactionSounds===false&&item.delegated){stopReaction(item);sound('stop');}}
 const observer=new IntersectionObserver(entries=>{for(const e of entries){const item=[...members].find(i=>i.element===e.target);if(item){item.visible=e.isIntersecting;item.viewer?.setVisible?.(e.isIntersecting);if(!item.visible)stopReaction(item);sync(item);}}announce();track(pointer);});
 function attach(el){if(el.dataset.nookAvatarMounted)return;el.dataset.nookAvatarMounted='true';const item={element:el,viewer:null,visible:true,gaze:{x:0,y:0},assetSerial:0,sourceSerial:0,requestedStyle:null,reactionSerial:0,reactionFrame:0,lastReaction:-Infinity,gesture:{previous:null,velocity:null,turns:0,firstTurn:0,cooldown:-Infinity}};members.add(item);
  load().then(()=>{if(!el.isConnected){members.delete(item);return;}const v=document.createElement('nook-avatar-model');item.viewer=v;v.setAttribute('aria-hidden','true');
   v.addEventListener('load',()=>{paint(item);expression(item);mouth(item);v.setGaze(item.gaze.x,item.gaze.y);});
   v.addEventListener('error',()=>{if(item.style!=='elemental'){assign(item,'elemental',window.__nookAvatarModels[persona(el)]);}else{v.remove();el.style.backgroundImage='url('+base+'elemental-01-'+persona(el)+'.png)';el.style.backgroundSize='contain';}});
   item.caption=document.createElement('span');item.caption.className='nook-avatar-caption';item.caption.setAttribute('aria-hidden','true');el.replaceChildren(v,item.caption);el.addEventListener('click',()=>react(item,'giggle'));el.addEventListener('contextmenu',e=>{if(eligible(item)){e.preventDefault();openMenu(item);}});el.addEventListener('keydown',e=>{if(e.key==='ContextMenu'||(e.shiftKey&&e.key==='F10')){e.preventDefault();openMenu(item);}else if(e.key==='Enter'||e.key===' '){e.preventDefault();react(item,'giggle');}});observer.observe(el);sync(item);
  }).catch(()=>{el.style.backgroundImage='url('+base+'elemental-01-'+persona(el)+'.png)';el.style.backgroundSize='contain';});
 }
 function scan(){document.querySelectorAll(selector).forEach(attach);for(const item of members)if(!item.element.isConnected){item.assetSerial++;if(activeMenu?.item===item)closeMenu();stopReaction(item);observer.unobserve(item.element);members.delete(item);}if(!members.size){cancelAnimationFrame(gazeFrame);gazeFrame=0;sound('stop');}announce();}
 const mutations=new MutationObserver(entries=>{if(entries.some(e=>e.type==='childList'))scan();for(const e of entries){const item=[...members].find(i=>i.element===e.target);if(item){mouth(item);expression(item);}}});mutations.observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['data-nook-speech-level','data-nook-speaking','data-nook-expression']});
 document.addEventListener('visibilitychange',()=>{for(const i of members){i.viewer?.setVisible?.(!document.hidden&&i.visible);sync(i);}if(document.hidden)sound('stop');announce();track(document.hidden?null:pointer);});
 document.addEventListener('keydown',e=>{if(e.key==='Escape'){closeMenu();members.forEach(stopReaction);sound('stop');}});
 document.addEventListener('pointerdown',e=>{if(activeMenu&&!activeMenu.node.contains(e.target))closeMenu();});
 window.addEventListener('pointermove',e=>{if(!window.webkit?.messageHandlers?.neroAvatarPresence)track({x:e.clientX,y:e.clientY,rangeX:innerWidth*.28,rangeY:innerHeight*.28});},{passive:true});
 window.NookAvatar=Object.freeze({
  speech(el,level,speaking){el.dataset.nookSpeechLevel=String(Number.isFinite(level)?Math.max(0,Math.min(1,level)):0);el.dataset.nookSpeaking=String(!!speaking);const i=[...members].find(i=>i.element===el);if(i)mouth(i);},
  expression(el,p={}){el.dataset.nookExpression=[p.pitch||0,p.roll||0,p.lift||0].join(',');const i=[...members].find(i=>i.element===el);if(i)expression(i);},
  pointer:track,
  setBusy(value){if(busy===!!value)return;busy=!!value;for(const item of members)sync(item);if(busy)sound('stop');},
  stop(){closeMenu();for(const i of members){stopReaction(i);i.viewer?.setFace?.({speak:0,laugh:0,smile:0,surprise:0,blink:0});}sound('stop');},
  reactionPose,playback,
  get wantsPointer(){return !document.hidden&&!reduced()&&[...members].some(i=>i.visible&&i.element.isConnected);},
  get status(){return {members:members.size,busy,following:announced};}
 });
 if(window.__neroAppearanceAPI)window.__neroAppearanceAPI.onChange(value=>{appearance=value;for(const item of members)sync(item);announce();track(pointer);});
 scan();
})();
