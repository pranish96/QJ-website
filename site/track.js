/* Website funnel tracking: page_landed -> waitlist_joined -> add_to_chrome_clicked.
   Each event is one row in the Supabase table public.web_events (insert-only for the public key; nobody can read it from the site).
   The visitor id is a random id kept in this browser so one person's steps can be linked; it holds no personal data.
   Only runs on the live site, so local previews don't add test rows. */
(() => {
  if (!/(^|\.)quickjobs\.pro$/.test(location.hostname)) { window.qjTrack = () => {}; return; }
  const URL = 'https://igaryftppmiybqhywkwb.supabase.co/rest/v1/web_events';
  const KEY = 'sb_publishable_nxs_TkYVSCBXH8H1lZXMHg_Xxqd8hSD';
  let vid = null;
  try { vid = localStorage.getItem('qj_vid'); } catch (e) {}
  if (!vid) {
    vid = (crypto.randomUUID ? crypto.randomUUID() : Date.now().toString(36) + Math.random().toString(36).slice(2, 12));
    try { localStorage.setItem('qj_vid', vid); } catch (e) {}
  }
  const q = new URLSearchParams(location.search);
  const cut = (v, n) => (v ? String(v).slice(0, n) : null);
  window.qjTrack = (name) => {
    try {
      fetch(URL, {
        method: 'POST', keepalive: true,
        headers: { apikey: KEY, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
        body: JSON.stringify({
          visitor_id: vid, name,
          page: cut(location.pathname, 500),
          referrer: cut(document.referrer, 500),
          utm_source: cut(q.get('utm_source'), 100),
          utm_medium: cut(q.get('utm_medium'), 100),
          utm_campaign: cut(q.get('utm_campaign'), 100),
          device_type: /Android|iPhone|iPad|iPod|Mobile/i.test(navigator.userAgent) ? 'mobile' : 'desktop'
        })
      }).catch(() => {});
    } catch (e) {}
  };
  qjTrack('page_landed');
  // Any link to the Chrome Web Store counts as "Add to Chrome clicked" (covers buttons added after joining, too).
  document.addEventListener('click', (e) => {
    const a = e.target.closest && e.target.closest('a[href*="chromewebstore.google.com"]');
    if (a) qjTrack('add_to_chrome_clicked');
  }, true);
})();
