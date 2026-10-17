(()=>{
 const panel=document.getElementById('carePanel'),status=document.getElementById('careStatus');
 const save=document.getElementById('careSave');
 const enabled=document.getElementById('careEnabled'),voice=document.getElementById('careVoice'),interval=document.getElementById('careInterval'),character=document.getElementById('careCharacter');
 document.getElementById('careOpen').onclick=async()=>{
  for(const field of [enabled,voice,interval,character,save])field.disabled=true;
  closeContextMenus();panel.hidden=false;status.textContent='读取提醒设置喵～';
  try{const r=await fetch('/api/care');if(!r.ok)throw Error('提醒服务暂时未连接喵～');const d=await r.json();enabled.checked=!!d.enabled;voice.checked=!!d.voice;interval.value=d.interval||300;character.value=d.character_name||'YUI';status.textContent=d.background?'后台提醒已连接，关闭挂件后也会留意猫粮喵～':'当前仅预览，后台提醒尚未连接喵～';}
  catch(e){status.textContent=e.message;}
  finally{for(const field of [enabled,voice,interval,character,save])field.disabled=false;}
 };
 document.getElementById('careClose').onclick=()=>panel.hidden=true;
 document.getElementById('careSave').onclick=async()=>{
  const seconds=Number(interval.value);if(!Number.isInteger(seconds)||seconds<60||seconds>86400){status.textContent='请填写 60～86400 秒的整数喵～';return;}
  try{const r=await fetch('/api/care',{method:'POST',headers:{'Content-Type':'application/json','X-Neko-CSRF':csrf},body:JSON.stringify({enabled:enabled.checked,voice:voice.checked,interval:seconds,character_name:character.value})}),d=await r.json();if(!r.ok)throw Error(d.error||'提醒设置暂未保存喵～');status.textContent='提醒设置已保存喵～';}catch(e){status.textContent=e.message;}
 };
 window.addEventListener('catfood:recordend',()=>panel.hidden=true);
})();
