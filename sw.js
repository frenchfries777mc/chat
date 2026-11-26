/* 설치형 앱용 최소 서비스 워커: 캐시 없이 항상 사이트에서 바로 받아서, 사이트가 업데이트되면 앱도 그대로 따라와요. */
self.addEventListener('install',function(){ self.skipWaiting(); });
self.addEventListener('activate',function(e){ e.waitUntil(self.clients.claim()); });
self.addEventListener('fetch',function(e){ e.respondWith(fetch(e.request)); });

/* 새 메시지 알림(Web Push) */
self.addEventListener('push',function(e){
  var d={}; try{ d=e.data.json(); }catch(x){}
  var ios=/iphone|ipad|ipod/i.test(self.navigator.userAgent||'');
  e.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(function(cl){
    /* 지금 이 앱을 보고 있으면 알림을 띄우지 않아요 (아이폰은 항상 띄워야 해서 예외) */
    if(!ios&&cl.some(function(c){ return c.visibilityState==='visible'&&c.focused; })) return;
    var vis=cl.some(function(c){ return c.visibilityState==='visible'; });
    if(!vis){ try{ if(self.navigator.setAppBadge) self.navigator.setAppBadge().catch(function(){}); }catch(x){} }
    return self.registration.showNotification(d.t||'Chat',{body:d.b||'',tag:d.tag||'chat',renotify:true,icon:'https://frenchfries777.com/games/pwa/icons/chat-192.png',badge:'https://frenchfries777.com/games/pwa/icons/chat-192.png',data:{room:d.room||null}}).then(function(){
      /* 그 방을 보고 있는 창이 있으면 그 창이 알림을 바로 치워요 */
      if(d.room) cl.forEach(function(c){ if(c.visibilityState==='visible') c.postMessage({clr:d.room}); }); });
  }));
});
self.addEventListener('notificationclick',function(e){
  e.notification.close(); var room=e.notification.data&&e.notification.data.room;
  e.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(function(cl){
    var c=cl[0]; if(c){ if(room) c.postMessage({room:room}); return c.focus(); }
    return self.clients.openWindow(room?('./?room='+encodeURIComponent(room)):'./'); }));
});
