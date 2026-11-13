/* 설치형 앱용 최소 서비스 워커: 캐시 없이 항상 사이트에서 바로 받아서, 사이트가 업데이트되면 앱도 그대로 따라와요. */
self.addEventListener('install',function(){ self.skipWaiting(); });
self.addEventListener('activate',function(e){ e.waitUntil(self.clients.claim()); });
self.addEventListener('fetch',function(e){ e.respondWith(fetch(e.request)); });
