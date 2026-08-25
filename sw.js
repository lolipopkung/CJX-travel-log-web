/* CJx Travel Log — service worker
   หน้าที่เดียว: ให้เปลือกแอปเปิดได้ตอนไม่มีสัญญาณ
   ข้อมูลจริงไม่ cache ที่นี่ (แอปมีคิวออฟไลน์ของตัวเองใน localStorage + IndexedDB)

   ขึ้นเวอร์ชันใหม่ทุกครั้งที่แก้ index.html ไม่งั้นเครื่องที่ติดตั้งไว้จะได้ของเก่า */
const V = 'cjx-travel-log-1e8baa03af';
const SHELL = ['./', './index.html', './manifest.webmanifest',
               './icon-192.png', './icon-512.png'];

self.addEventListener('install', (e) => {
  e.waitUntil((async () => {
    const c = await caches.open(V);
    // ไฟล์บางตัวอาจยังไม่มี — อย่าให้ install ล้มทั้งชุด
    await Promise.all(SHELL.map(u => c.add(u).catch(() => {})));
    self.skipWaiting();
  })());
});

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    for (const k of await caches.keys()) if (k !== V) await caches.delete(k);
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (e) => {
  const r = e.request;
  if (r.method !== 'GET') return;
  const url = new URL(r.url);

  // อย่าแตะ Supabase / API ใด ๆ — ต้องได้ข้อมูลสด หรือ error จริงเพื่อให้แอปเข้าคิวออฟไลน์
  if (url.origin !== self.location.origin) return;

  // network-first สำหรับหน้าเว็บ เพื่อให้ผู้ใช้ได้เวอร์ชันใหม่เสมอเมื่อออนไลน์
  e.respondWith((async () => {
    try {
      const res = await fetch(r);
      if (res && res.ok) (await caches.open(V)).put(r, res.clone());
      return res;
    } catch {
      const hit = await caches.match(r, { ignoreSearch: true });
      return hit || caches.match('./index.html');
    }
  })());
});
