// Nav toggle (mobile)
const navToggle=document.querySelector('.nav-toggle');
const nav=document.querySelector('.site-nav');
const yearEl=document.getElementById('year');
if(navToggle){
  navToggle.addEventListener('click',()=>{
    const open=nav.classList.toggle('open');
    navToggle.setAttribute('aria-expanded',String(open));
  });
}

// Smooth scroll
document.querySelectorAll('a[href^="#"]').forEach(a=>{
  a.addEventListener('click',e=>{
    const id=a.getAttribute('href');
    if(id && id.length>1){
      e.preventDefault();
      document.querySelector(id)?.scrollIntoView({behavior:'smooth',block:'start'});
      nav?.classList.remove('open');
      navToggle?.setAttribute('aria-expanded','false');
    }
  });
});

// Year
if(yearEl){yearEl.textContent=String(new Date().getFullYear());}

// Theme toggle (light/dark) with system preference and persistence
const THEME_KEY='uhda.theme';
const root=document.documentElement;
const themeBtn=document.querySelector('.theme-toggle');

function systemPrefersDark(){return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches}
function applyTheme(theme){
  if(theme==='dark' || (theme===null && systemPrefersDark())){
    root.setAttribute('data-theme','dark');
    if(themeBtn) themeBtn.textContent='☀️';
  }else{
    root.removeAttribute('data-theme');
    if(themeBtn) themeBtn.textContent='🌙';
  }
}
function currentTheme(){return localStorage.getItem(THEME_KEY)}
applyTheme(currentTheme());

if(themeBtn){
  themeBtn.addEventListener('click',()=>{
    const saved=currentTheme();
    const isDark=(saved? saved==='dark' : systemPrefersDark());
    const next=isDark?'light':'dark';
    localStorage.setItem(THEME_KEY,next);
    applyTheme(next);
  });
}

// Observe system changes only if user hasn't chosen explicitly
try{
  if(window.matchMedia){
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change',()=>{
      if(currentTheme()===null){applyTheme(null)}
    });
  }
}catch{}

// Reveal on scroll
const revealEls=[...document.querySelectorAll('.reveal')];
if('IntersectionObserver' in window){
  const io=new IntersectionObserver((entries)=>{
    entries.forEach(en=>{if(en.isIntersecting){en.target.classList.add('show');io.unobserve(en.target);}});
  },{root:null,rootMargin:'0px 0px -10% 0px',threshold:.1});
  revealEls.forEach(el=>io.observe(el));
}else{
  revealEls.forEach(el=>el.classList.add('show'));
}

// Lightbox for screenshots
function openLightbox(src,alt){
  const backdrop=document.createElement('div');
  backdrop.className='lightbox-backdrop';
  backdrop.tabIndex=0;
  const img=document.createElement('img');
  img.className='lightbox-img';
  img.src=src; img.alt=alt||'';
  backdrop.appendChild(img);
  function close(){
    document.removeEventListener('keydown',onKey);
    backdrop.remove();
  }
  function onKey(e){ if(e.key==='Escape'){ close(); } }
  backdrop.addEventListener('click',e=>{ if(e.target===backdrop) close(); });
  document.addEventListener('keydown',onKey);
  document.body.appendChild(backdrop);
  backdrop.focus();
}

// Slider for screenshots
(function initSlider(){
  const slider=document.querySelector('#shots .slider');
  if(!slider) return;
  const track=slider.querySelector('.slides-track');
  const slides=[...slider.querySelectorAll('.slide')];
  const prevBtn=slider.querySelector('.prev');
  const nextBtn=slider.querySelector('.next');
  const dotsWrap=slider.querySelector('.dots');
  let index=0; let startX=null; let deltaX=0; let locked=false; let slideW=0; let moved=false; let timer=null;

  // Ensure images get a proper src (handle spaces/Arabic via encodeURI)
  slides.forEach(img=>{
    const ds=img.getAttribute('data-src');
    if(ds){ img.src=encodeURI(ds); }
  });

  // Dots
  const dots=slides.map((_,i)=>{
    const d=document.createElement('button');
    d.className='dot'+(i===0?' active':'');
    d.type='button';
    d.setAttribute('aria-label','الشريحة '+(i+1));
    d.addEventListener('click',()=>goTo(i));
    dotsWrap.appendChild(d);
    return d;
  });

  function layout(){
    const surface=slider.querySelector('.slides');
    slideW=surface.clientWidth;
    slides.forEach(s=>{s.style.width=slideW+'px';});
    track.style.width=(slides.length*slideW)+'px';
    update();
  }
  function update(){
    const offset=-index*slideW;
    track.style.transform=`translateX(${offset}px)`;
    dots.forEach((d,i)=>d.classList.toggle('active',i===index));
  }
  function goTo(i){ index=(i+slides.length)%slides.length; update(); }
  function next(){ goTo(index+1); }
  function prev(){ goTo(index-1); }

  if(prevBtn) prevBtn.addEventListener('click',prev);
  if(nextBtn) nextBtn.addEventListener('click',next);

  // Touch/drag for mobile
  const surface=slider.querySelector('.slides');
  function onStart(e){
    if(locked) return; locked=true; startX=(e.touches? e.touches[0].clientX : e.clientX); deltaX=0; moved=false;
  }
  function onMove(e){ if(!locked) return; const x=(e.touches? e.touches[0].clientX : e.clientX); deltaX=x-startX; if(Math.abs(deltaX)>5) moved=true; }
  function onEnd(){
    if(!locked) return; const threshold=40; // px
    if(Math.abs(deltaX)>threshold){ if(deltaX>0){ // swipe right
      // In RTL UI, swipe right should go to next visually; but our track uses translateX negative for next
      prev();
    }else{ next(); } }
    locked=false; startX=null; deltaX=0;
  }
  surface.addEventListener('touchstart',onStart,{passive:true});
  surface.addEventListener('touchmove',onMove,{passive:true});
  surface.addEventListener('touchend',onEnd);
  surface.addEventListener('mousedown',onStart);
  window.addEventListener('mousemove',onMove);
  window.addEventListener('mouseup',onEnd);

  // Lightbox on click
  slides.forEach(img=>img.addEventListener('click',()=>{ if(!moved) openLightbox(img.src,img.alt); }));

  // Keyboard arrows
  function onKey(e){
    if(e.key==='ArrowLeft') { // in RTL this is visually next
      next();
    } else if(e.key==='ArrowRight') {
      prev();
    }
  }
  slider.addEventListener('mouseenter',()=>pause());
  slider.addEventListener('mouseleave',()=>play());
  slider.addEventListener('focusin',()=>pause());
  document.addEventListener('keydown',onKey);

  // Autoplay with pause on hover/visibility
  function play(){ stop(); timer=setInterval(next, 4000); }
  function pause(){ stop(); }
  function stop(){ if(timer){clearInterval(timer); timer=null;} }
  document.addEventListener('visibilitychange',()=>{ if(document.hidden) pause(); else play(); });

  window.addEventListener('resize',()=>layout());
  layout();
  play();
})();

// Scroll-snap carousel for screenshots
(function(){
  const carousel=document.querySelector('#shots .carousel');
  if(!carousel) return;
  const track=carousel.querySelector('.carousel-track');
  const items=[...carousel.querySelectorAll('.carousel-item')];
  const prev=carousel.querySelector('.prev');
  const next=carousel.querySelector('.next');
  const dotsWrap=carousel.querySelector('.carousel-dots');
  const status=carousel.querySelector('#carousel-status');
  let index=0; let raf=null;
  if(dotsWrap) dotsWrap.setAttribute('role','tablist');
  const dots=items.map((_,i)=>{const b=document.createElement('button'); b.className='c-dot'+(i===0?' active':''); b.type='button'; b.setAttribute('aria-label',`اذهب إلى الشريحة ${i+1}`); b.setAttribute('role','tab'); b.addEventListener('click',()=>goTo(i)); dotsWrap.appendChild(b); return b;});
  function update(){
    dots.forEach((d,i)=>{ const active=i===index; d.classList.toggle('active',active); d.setAttribute('aria-selected',active? 'true':'false'); });
    if(status){ status.textContent = `الشريحة ${index+1} من ${items.length}`; }
  }
  function goTo(i){ index=(i+items.length)%items.length; items[index].scrollIntoView({behavior:'smooth',inline:'center',block:'nearest'}); update(); }
  function onPrev(){ goTo(index-1); }
  function onNext(){ goTo(index+1); }
  if(prev) prev.addEventListener('click',onPrev);
  if(next) next.addEventListener('click',onNext);
  // Keyboard controls on the track
  track.addEventListener('keydown',e=>{
    if(e.key==='ArrowLeft'){ e.preventDefault(); onNext(); }
    else if(e.key==='ArrowRight'){ e.preventDefault(); onPrev(); }
    else if(e.key==='Home'){ e.preventDefault(); goTo(0); }
    else if(e.key==='End'){ e.preventDefault(); goTo(items.length-1); }
  });
  function onScroll(){ if(raf) cancelAnimationFrame(raf); raf=requestAnimationFrame(()=>{ const rect=track.getBoundingClientRect(); let best=0; let bestDist=Infinity; items.forEach((it,i)=>{ const r=it.getBoundingClientRect(); const center=r.left+r.width/2; const dist=Math.abs(center-(rect.left+rect.width/2)); if(dist<bestDist){bestDist=dist; best=i;} }); index=best; update(); }); }
  track.addEventListener('scroll',onScroll,{passive:true});
  window.addEventListener('resize',onScroll);
  update();
})();

// Code viewer for video page: load supabase.sql and enable copy/download
(function initCodeViewer(){
  const wrap=document.querySelector('#sql-viewer');
  if(!wrap) return;
  const pre=wrap.querySelector('pre');
  const copyBtn=wrap.querySelector('[data-copy]');
  const dlBtn=wrap.querySelector('[data-download]');
  async function load(){
    try{
      if(location.protocol==='file:'){
        // Avoid auto-loading/auto-downloading on file://
        pre.textContent='تعذر عرض الملف محلياً عبر file://. شغّل خادماً محلياً لعرض النص أو استخدم زر التنزيل.';
        dlBtn.disabled=false;
        dlBtn.addEventListener('click',()=>{ const a=document.createElement('a'); a.href='supabase.sql'; a.download='supabase.sql'; a.click(); });
        // Leave copy disabled because النص غير متاح للقراءة محلياً
        return;
      } else {
        const res=await fetch('supabase.sql');
        if(!res.ok) throw new Error('fetch failed');
        const text=await res.text();
        pre.textContent=text;
        copyBtn.disabled=false; dlBtn.disabled=false;
        copyBtn.addEventListener('click',async()=>{
          const original=copyBtn.textContent;
          async function writeClipboard(){
            try{
              await navigator.clipboard.writeText(text);
              return true;
            }catch{
              try{
                const ta=document.createElement('textarea');
                ta.value=text; ta.style.position='fixed'; ta.style.opacity='0'; ta.setAttribute('readonly','');
                document.body.appendChild(ta); ta.select(); ta.setSelectionRange(0, ta.value.length);
                const ok=document.execCommand && document.execCommand('copy');
                ta.remove();
                return !!ok;
              }catch{return false;}
            }
          }
          const ok=await writeClipboard();
          if(ok){ copyBtn.textContent='تم النسخ'; setTimeout(()=>copyBtn.textContent=original,1200); }
        });
        dlBtn.addEventListener('click',()=>{
          const blob=new Blob([text],{type:'text/plain'});
          const url=URL.createObjectURL(blob);
          const a=document.createElement('a');
          a.href=url; a.download='supabase.sql'; a.click();
          setTimeout(()=>URL.revokeObjectURL(url),1000);
        });
      }
    }catch(e){
      pre.textContent='تعذر عرض الملف محلياً. استخدم زر التنزيل المباشر.';
      // direct link fallback
      dlBtn.addEventListener('click',()=>{ const a=document.createElement('a'); a.href='supabase.sql'; a.download='supabase.sql'; a.click(); });
    }
  }
  load();
})();

// Download buttons (placeholder for analytics hook)
['download-btn','download-btn-2'].forEach(id=>{
  const btn=document.getElementById(id);
  if(btn){btn.addEventListener('click',()=>{/* hook for analytics */});}
});
