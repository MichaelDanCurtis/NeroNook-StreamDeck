/* Matches PluginSeasonalMotion; deterministic finite overlay, no audio/actions. */
function sampleSeasonalParticles(scene, overlay, elapsed) {
  const duration=scene.intensity==='low'?12:24;
  if(!Number.isFinite(elapsed)||elapsed<0||elapsed>=duration||scene.intensity==='off'||['memorial','veterans'].includes(scene.holiday)||overlay==='none')return [];
  const cap=scene.intensity==='low'?Math.min(scene.day,6):Math.min(scene.day*2,24);
  return Array.from({length:cap},(_,i)=>{
    const kind=({snow:'snow',sparks:'star',petals:'petal',leaves:'leaf',bats:i%3===0?'bat':'leaf',hearts:'heart',confetti:'confetti'})[overlay]||'star';
    const phase=elapsed*(kind==='bat'?5.5:1.6)+i*1.9,drift=Math.sin(elapsed*.7+i)*.025;
    const seedX=((i*43+13)%97)/100,seedY=((i*31+7)%101)/100;
    const rising=kind==='heart'||kind==='star',speed=kind==='bat'?.07:kind==='snow'?.035:.022;
    const travel=(seedY+elapsed*speed)%1,x=Math.min(.985,Math.max(.015,seedX+drift));
    const y=kind==='bat'?Math.min(.30,Math.max(.06,seedY*.25+Math.sin(elapsed+i)*.025)):rising?1-travel:travel;
    const size=kind==='bat'?10:kind==='snow'?1.4:kind==='heart'?5:kind==='leaf'?4.2:3;
    const edgeFade=Math.min(1,elapsed/.6)*Math.min(1,(duration-elapsed)/.8);
    return {kind,x,y,size,rotation:kind==='bat'?Math.sin(elapsed+i)*.12:phase*.4,phase,opacity:edgeFade*(kind==='bat'?.55:.40)};
  });
}
/* Local static art plus a finite overlay. No microphone, network or action API. */
if (document.body?.hasAttribute('data-nook-seasonal-surface')) {
  const assets=new Map(seasonalData.catalog.assets.map(a=>[a.id,a])), plans=seasonalData.plans;
  const central=new Set(['tree.original','tree.center','tree.right','gift.left','gift.right','gift.front-left','gift.front-right','lights.trees']);
  const protect='[data-nook-seasonal-protect],.nc-brand,.nc-bottom,.nc-title,.nc-subtitle,.nc-words,.nc-wave,.nc-notice,.nc-drawer,button,input,textarea,select,summary';
  let appearance=null, visible=false, disposed=false, pending=0, animation=0, epoch=0, current=null, geometry=null, sceneKey='', deadline=0, began=0, lastFrame=0, rasterKey='';
  const images=new Map(), canvases=['background','overlay'].map(role=>{
    const canvas=document.createElement('canvas');canvas.className='nook-seasonal-canvas';canvas.dataset.role=role;canvas.setAttribute('aria-hidden','true');document.body.append(canvas);return canvas;
  });
  const contexts=canvases.map(c=>c.getContext('2d'));
  const visibilityStyles=new Map();
  const motion=matchMedia('(prefers-reduced-motion:reduce)'), transparency=matchMedia('(prefers-reduced-transparency:reduce)');
  const finite=(v)=>Number.isFinite(v), clamp=(v,a,b)=>Math.min(b,Math.max(a,v));
  function rect(el) {
    if (!el || el.closest('[hidden]')) return null;
    const closed=el.closest('details:not([open])');
    if(closed&&!el.closest('summary'))return null;
    // Popovers often hide their parent with opacity/visibility while children
    // retain ordinary computed styles and rectangles. Such controls reserve no art.
    for(let node=el;node;node=node.parentElement){
      let style=visibilityStyles.get(node);if(!style){style=getComputedStyle(node);visibilityStyles.set(node,style);}
      if(style.display==='none'||style.visibility==='hidden'||Number(style.opacity)===0)return null;
    }
    const r=el.getBoundingClientRect();
    return r.width<2||r.height<2||r.bottom<=0||r.top>=innerHeight ? null:{x:r.x,y:r.y,width:r.width,height:r.height};
  }
  function subtract(region,hole) {
    const x=Math.max(region.x,hole.x),y=Math.max(region.y,hole.y),r=Math.min(region.x+region.width,hole.x+hole.width),b=Math.min(region.y+region.height,hole.y+hole.height);
    if(r<=x||b<=y)return [region];
    return [{x:region.x,y:region.y,width:region.width,height:y-region.y},{x:region.x,y:b,width:region.width,height:region.y+region.height-b},{x:region.x,y,width:x-region.x,height:b-y},{x:r,y,width:region.x+region.width-r,height:b-y}].filter(v=>v.width>.1&&v.height>.1);
  }
  function allowed() {
    // Sequential subtraction gives disjoint allowed rectangles. Overlapping
    // controls cannot reopen an earlier hole as an even/odd clip would.
    let regions=[{x:0,y:0,width:innerWidth,height:innerHeight}],holes=[];
    for(const el of document.querySelectorAll(protect)) {
      if(el.closest('.nook-seasonal-canvas'))continue;
      const r=rect(el);if(!r)continue;
      if(holes.some(h=>r.x>=h.x&&r.y>=h.y&&r.x+r.width<=h.x+h.width&&r.y+r.height<=h.y+h.height))continue;
      holes.push({x:r.x-6,y:r.y-5,width:r.width+12,height:r.height+10});
      if(holes.length>80)return [];
    }
    for(const hole of holes){regions=regions.flatMap(r=>subtract(r,hole));if(regions.length>512)return [];}
    return regions;
  }
  function fit(asset,frame,w,h) {
    const x=frame.x*w,y=frame.y*h,fw=frame.width*w,fh=frame.height*h;
    if(fw/fh>asset.aspectRatio){const width=fh*asset.aspectRatio;return {x:x+(fw-width)/2,y,width,height:fh};}
    const height=fw/asset.aspectRatio;return {x,y:y+fh-height,width:fw,height};
  }
  function clip(ctx) {ctx.beginPath();for(const r of geometry.regions)ctx.rect(r.x,r.y,r.width,r.height);ctx.clip();}
  function clear() {rasterKey='';for(let i=0;i<2;i++)contexts[i]?.clearRect(0,0,canvases[i].width,canvases[i].height);}
  function halt() {cancelAnimationFrame(animation);animation=0;contexts[1]?.clearRect(0,0,innerWidth,innerHeight);}
  function image(name) {
    if(images.has(name))return images.get(name);
    const record={ready:false,image:new Image()};images.set(name,record);const token=epoch;
    record.image.onload=()=>{record.ready=true;if(!disposed&&token===epoch)schedule();};
    record.image.onerror=()=>{record.ready=false;};
    record.image.src='nook-view://surface/__nook_sdk__/'+name;
    return record;
  }
  function rebuild() {
    pending=0;if(disposed)return;
    visibilityStyles.clear();
    const scene=appearance?.seasonalSurface||appearance?.seasonalScene;
    const valid=scene?.version===1&&Number.isInteger(scene.year)&&scene.year>=1900&&scene.year<=9999&&Number.isInteger(scene.day)&&['off','low','standard'].includes(scene.intensity);
    const plan=valid?plans[scene.holiday+'.'+scene.day]:null;
    const anchor=[...document.querySelectorAll('[data-nook-seasonal-anchor]')].map(rect).find(Boolean);
    if(!visible||document.hidden||!plan||scene.totalDays!==plan.scene.totalDays||!anchor||appearance?.increasedContrast) {
      current=null;geometry=null;delete document.body.dataset.nookSeasonalActive;halt();clear();return;
    }
    const w=innerWidth,h=innerHeight;if(w<200||h<160){current=null;geometry=null;halt();clear();return;}
    const dpr=Math.min(2,devicePixelRatio||1);
    for(let i=0;i<2;i++)if(canvases[i].width!==Math.round(w*dpr)||canvases[i].height!==Math.round(h*dpr)){canvases[i].width=Math.round(w*dpr);canvases[i].height=Math.round(h*dpr);contexts[i].setTransform(dpr,0,0,dpr,0,0);rasterKey='';}
    const floor=clamp((anchor.y+anchor.height)/h,.24,.68),cx=(anchor.x+anchor.width/2)/w;
    const oldFloor=plan.layout.avatar.y+plan.layout.avatar.height,oldCX=plan.layout.avatar.x+plan.layout.avatar.width/2;
    const ratio=clamp((floor-.035)/.465,.48,1)/clamp((oldFloor-.035)/.465,.48,1);
    const layers=plan.layers.map(layer=>{
      const f={...layer.frame};
      if(central.has(layer.id)){f.x=cx+(f.x-oldCX)*ratio;f.y=floor+(f.y-oldFloor)*ratio;f.width*=ratio;f.height*=ratio;}
      else if(layer.id.startsWith('hero.')){f.x+=cx-oldCX;f.y+=floor-oldFloor;}
      f.x=clamp(f.x,0,1-f.width);f.y=clamp(f.y,0,1-f.height);
      const asset=assets.get(layer.asset);return {...layer,asset,box:fit(asset,f,w,h)};
    }).sort((a,b)=>a.depth-b.depth);
    geometry={regions:allowed(),layers,anchor};current=scene;document.body.dataset.nookSeasonalActive='true';
    const dark=appearance?.scheme==='dark';
    const records=layers.map(l=>image(dark?l.asset.files.dark:l.asset.files.light));
    const used=new Set(layers.map(l=>dark?l.asset.files.dark:l.asset.files.light));
    for(const [name,record] of images)if(images.size>24&&!used.has(name)){record.image.onload=null;record.image.onerror=null;images.delete(name);}
    const key=JSON.stringify([scene.holiday,scene.day,dark,w,h,geometry.regions,layers.map(l=>[l.id,l.box]),records.map(r=>r.ready)]);
    if(key!==rasterKey){
      rasterKey=key;const ctx=contexts[0];ctx.clearRect(0,0,w,h);ctx.save();clip(ctx);
      for(let index=0;index<layers.length;index++){const l=layers[index],r=l.box,record=records[index];if(!record.ready)continue;ctx.save();if(l.mirrored){ctx.translate(2*r.x+r.width,0);ctx.scale(-1,1);}ctx.drawImage(record.image,r.x,r.y,r.width,r.height);ctx.restore();}
      ctx.restore();
    }
    const next=[scene.holiday,scene.year,scene.day,scene.intensity].join('.');
    if(next!==sceneKey){sceneKey=next;began=performance.now();deadline=began+(scene.intensity==='low'?12000:24000);}
    const mayAnimate=scene.intensity!=='off'&&plan.overlay!=='none'&&!appearance?.reduceMotion&&!appearance?.reduceTransparency&&!motion.matches&&!transparency.matches;
    if(!mayAnimate||performance.now()>=deadline){halt();return;}
    if(!animation)animation=requestAnimationFrame(tick);
  }
  function tick(now) {
    animation=0;if(disposed||!visible||document.hidden||!current||!geometry||now>=deadline){halt();return;}
    if(now-lastFrame<1000/12){animation=requestAnimationFrame(tick);return;}lastFrame=now;
    const ctx=contexts[1],w=innerWidth,h=innerHeight,t=(now-began)/1000;
    ctx.clearRect(0,0,w,h);ctx.save();clip(ctx);
    for(const l of geometry.layers)for(let i=0;i<l.asset.overlayAnchors.length;i++) {
      const a=l.asset.overlayAnchors[i],r=l.box,x=r.x+(l.mirrored?1-a.x:a.x)*r.width,y=r.y+a.y*r.height,radius=Math.max(1.4,a.radius*r.height*2.8)*3;
      const g=ctx.createRadialGradient(x,y,0,x,y,radius);g.addColorStop(0,a.color);g.addColorStop(1,a.color+'00');
      ctx.globalAlpha=.18+.09*(1+Math.sin(t*1.6+i*1.9));ctx.fillStyle=g;ctx.fillRect(x-radius,y-radius,radius*2,radius*2);
    }
    const kind=plans[current.holiday+'.'+current.day].overlay;
    for(const p of sampleSeasonalParticles(current,kind,t)) {
      const x=p.x*w,y=p.y*h,a=geometry.anchor;
      if(x>=a.x-8&&x<=a.x+a.width+8&&y>=a.y-8&&y<=a.y+a.height+8)continue;
      ctx.save();ctx.translate(x,y);ctx.rotate(p.rotation);ctx.scale(p.size,p.size);ctx.globalAlpha=p.opacity;
      ctx.fillStyle=({bat:'#69517d',leaf:'#c47732',petal:'#da8099',heart:'#da8099',snow:'#eef6ff'})[p.kind]||'#e7bf70';
      ctx.beginPath();
      switch(p.kind) {
        case 'snow':ctx.arc(0,0,1,0,Math.PI*2);break;
        case 'confetti':ctx.rect(-.5,-1.2,1,2.4);break;
        case 'heart':ctx.moveTo(0,1);ctx.bezierCurveTo(-2,-.25,-.8,-1.5,0,-.55);ctx.bezierCurveTo(.8,-1.5,2,-.25,0,1);break;
        case 'bat':{const wing=.5+Math.sin(p.phase)*.4;ctx.moveTo(0,.1);ctx.lineTo(-1.6,-wing);ctx.quadraticCurveTo(-1,0,-.4,.4);ctx.lineTo(0,.2);ctx.lineTo(.4,.4);ctx.quadraticCurveTo(1,0,1.6,-wing);ctx.closePath();break;}
        case 'leaf':case 'petal':ctx.moveTo(-1,0);ctx.quadraticCurveTo(0,-1.2,1,0);ctx.quadraticCurveTo(0,.8,-1,0);break;
        default:for(let i=0;i<8;i++){const angle=i*Math.PI/4-Math.PI/2,r=i%2===0?1:.3;const x=Math.cos(angle)*r,y=Math.sin(angle)*r;i===0?ctx.moveTo(x,y):ctx.lineTo(x,y);}ctx.closePath();
      }
      ctx.fill();ctx.restore();
    }
    ctx.restore();animation=requestAnimationFrame(tick);
  }
  function schedule(){if(!disposed&&!pending)pending=requestAnimationFrame(rebuild);}
  const observer=new MutationObserver(records=>{
    if(records.some(r=>!r.target?.closest?.('.nook-seasonal-canvas')&&!r.target?.closest?.('.nook-presence')&&!(r.target===document.body&&r.attributeName==='data-nook-seasonal-active')))schedule();
  });
  observer.observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['hidden','class','style'],characterData:true});
  const resize=new ResizeObserver(schedule);resize.observe(document.body);
  const visibility=()=>{if(document.hidden)halt();schedule();};
  document.addEventListener('visibilitychange',visibility);window.addEventListener('resize',schedule);
  motion.addEventListener('change',schedule);transparency.addEventListener('change',schedule);
  const removeAppearance=window.__neroAppearanceAPI?.onChange(value=>{appearance=value;schedule();});
  Object.defineProperty(window,'NookSeasonal',{value:Object.freeze({
    setVisible(value){visible=value===true;if(!visible)halt();schedule();},
    dispose(){if(disposed)return;disposed=true;epoch++;halt();cancelAnimationFrame(pending);pending=0;observer.disconnect();resize.disconnect();removeAppearance?.();document.removeEventListener('visibilitychange',visibility);window.removeEventListener('resize',schedule);motion.removeEventListener('change',schedule);transparency.removeEventListener('change',schedule);for(const c of canvases)c.remove();images.clear();delete document.body.dataset.nookSeasonalActive;},
    get status(){return {visible,active:!!current,animating:!!animation,layers:geometry?.layers.length||0,regions:geometry?.regions.length||0,sceneKey};}
  })});
}
