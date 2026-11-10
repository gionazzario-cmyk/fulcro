import Foundation

/// La pagina per l'iPad: scura, vetro, pulsanti rapidi. Nessuna risorsa esterna,
/// cosi funziona anche senza internet (Jarvis gira in locale).
enum WebPage {
    static let html = """
    <!doctype html>
    <html lang="it">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <title>Jarvis</title>
    <style>
      :root { color-scheme: dark; }
      * { box-sizing: border-box; }
      body {
        margin: 0; min-height: 100vh; font-family: -apple-system, "SF Pro Text", system-ui, sans-serif;
        background: radial-gradient(120% 100% at 50% 0%, #052436 0%, #031020 55%, #01050a 100%);
        color: #eef1f6; display: flex; flex-direction: column;
      }
      header {
        padding: max(env(safe-area-inset-top), 14px) 18px 12px;
        background: rgba(28,32,42,.55); backdrop-filter: blur(22px) saturate(160%);
        -webkit-backdrop-filter: blur(22px) saturate(160%);
        border-bottom: 1px solid rgba(255,255,255,.08);
        display: flex; align-items: center; gap: 10px; position: sticky; top: 0; z-index: 5;
      }
      header .dot { width: 9px; height: 9px; border-radius: 50%; background: #30d158; box-shadow: 0 0 10px #30d158; }
      header h1 { font-size: 17px; margin: 0; font-weight: 600; letter-spacing: .2px; }
      header .sub { margin-left: auto; font-size: 12px; color: #9aa3b2; }
      main { flex: 1; overflow-y: auto; padding: 16px 14px 8px; display: flex; flex-direction: column; gap: 10px; }
      .msg { max-width: 78%; padding: 11px 14px; border-radius: 18px; line-height: 1.35; font-size: 16px;
             white-space: pre-wrap; word-break: break-word; backdrop-filter: blur(12px); }
      .me { align-self: flex-end; background: rgba(0,240,255,.16); border: 1px solid rgba(0,240,255,.42); border-bottom-right-radius: 7px; }
      .jarvis { align-self: flex-start; background: rgba(120,128,145,.16); border: 1px solid rgba(255,255,255,.07); border-bottom-left-radius: 7px; }
      .wait { align-self: flex-start; color: #8b93a3; font-size: 14px; padding: 4px 12px; }
      .chips { display: flex; gap: 8px; overflow-x: auto; padding: 8px 14px 4px; scrollbar-width: none; }
      .chips::-webkit-scrollbar { display: none; }
      .chip { flex: 0 0 auto; padding: 8px 13px; border-radius: 15px; font-size: 14px; color: #dbe1ec;
              background: rgba(255,255,255,.07); border: 1px solid rgba(255,255,255,.1); }
      .chip:active { background: rgba(255,255,255,.16); }
      footer { padding: 10px 12px max(env(safe-area-inset-bottom), 14px); display: flex; gap: 9px; align-items: flex-end;
               background: rgba(20,23,30,.6); backdrop-filter: blur(22px); -webkit-backdrop-filter: blur(22px);
               border-top: 1px solid rgba(255,255,255,.07); }
      textarea { flex: 1; resize: none; max-height: 120px; border-radius: 16px; padding: 11px 14px; font-size: 16px;
                 font-family: inherit; color: #eef1f6; background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.12); outline: none; }
      textarea:focus { border-color: rgba(0,240,255,.65); box-shadow: 0 0 12px rgba(0,240,255,.15); }
      button.send { width: 44px; height: 44px; border-radius: 50%; border: none; font-size: 19px; color: #fff;
                    background: linear-gradient(180deg,#ff5a4d,#c00d1f); box-shadow: 0 4px 14px rgba(192,13,31,.45); }
      button.send:disabled { opacity: .4; }
      .veil { position: fixed; inset: 0; background: rgba(6,7,10,.82); backdrop-filter: blur(18px);
              display: flex; align-items: center; justify-content: center; padding: 26px; z-index: 20; }
      .card { width: 100%; max-width: 340px; background: rgba(40,45,58,.9); border: 1px solid rgba(255,255,255,.12);
              border-radius: 22px; padding: 22px; text-align: center; }
      .card h2 { margin: 0 0 6px; font-size: 19px; }
      .card p { margin: 0 0 16px; font-size: 13px; color: #9aa3b2; line-height: 1.4; }
      .card input { width: 100%; text-align: center; letter-spacing: 5px; font-size: 20px; text-transform: uppercase;
                    padding: 12px; border-radius: 13px; background: rgba(255,255,255,.08); color: #fff;
                    border: 1px solid rgba(255,255,255,.14); outline: none; }
      .card button { margin-top: 14px; width: 100%; padding: 13px; border-radius: 13px; border: none;
                     background: #c00d1f; color: #fff; font-size: 16px; }
      .hide { display: none !important; }
    </style>
    </head>
    <body>
    <header>
      <span class="dot" id="dot"></span>
      <h1>Jarvis</h1>
      <span class="sub" id="sub">collego…</span>
    </header>

    <main id="log"></main>

    <div class="chips" id="chips"></div>

    <footer>
      <textarea id="box" rows="1" placeholder="Scrivi a \(Marca.nome)…"></textarea>
      <button class="send" id="go" aria-label="Invia">↑</button>
    </footer>

    <div class="veil" id="veil">
      <div class="card">
        <h2>Codice di Jarvis</h2>
        <p>Lo trovi nel pannello di Jarvis sul Mac: e' la riga sotto il pulsante del microfono.</p>
        <input id="pin" inputmode="text" autocomplete="off" spellcheck="false" maxlength="6" placeholder="••••••">
        <button id="ok">Entra</button>
      </div>
    </div>

    <script>
    const QUICK = ["Classifica piloti F1", "Prossima gara", "Meteo",
                   "Musica play o pausa", "Spazio libero sul disco", "Quante mail non lette ho?"];
    const log = document.getElementById('log'), box = document.getElementById('box'),
          go = document.getElementById('go'), sub = document.getElementById('sub'),
          dot = document.getElementById('dot'), veil = document.getElementById('veil'),
          pinEl = document.getElementById('pin'), chips = document.getElementById('chips');
    let busy = false;

    let pin = localStorage.getItem('jarvis-pin') || '';
    if (pin) veil.classList.add('hide');

    function bubble(cls, text) {
      const d = document.createElement('div');
      d.className = 'msg ' + cls;
      d.textContent = text;
      log.appendChild(d);
      log.scrollTop = log.scrollHeight;
      return d;
    }

    QUICK.forEach(q => {
      const c = document.createElement('div');
      c.className = 'chip'; c.textContent = q;
      c.onclick = () => send(q);
      chips.appendChild(c);
    });

    async function send(text) {
      const t = (text || box.value).trim();
      if (!t || busy) return;
      if (!pin) { veil.classList.remove('hide'); pinEl.focus(); return; }
      box.value = ''; box.style.height = 'auto';
      bubble('me', t);
      const w = document.createElement('div');
      w.className = 'wait'; w.textContent = 'Jarvis sta pensando…';
      log.appendChild(w); log.scrollTop = log.scrollHeight;
      busy = true; go.disabled = true; dot.style.background = '#ff9f0a'; dot.style.boxShadow = '0 0 10px #ff9f0a';
      try {
        const r = await fetch('/chat', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-Jarvis-Pin': pin },
          body: JSON.stringify({ testo: t })
        });
        const j = await r.json();
        w.remove();
        if (r.status === 401) {
          localStorage.removeItem('jarvis-pin'); pin = '';
          bubble('jarvis', 'Codice sbagliato: rimetti quello del Mac.');
          veil.classList.remove('hide');
        } else bubble('jarvis', j.risposta || j.errore || 'nessuna risposta');
      } catch (e) {
        w.remove();
        bubble('jarvis', 'Non raggiungo il Mac: sei sulla stessa rete Wi-Fi?');
        sub.textContent = 'offline';
      } finally {
        busy = false; go.disabled = false;
        dot.style.background = '#30d158'; dot.style.boxShadow = '0 0 10px #30d158';
      }
    }

    document.getElementById('ok').onclick = () => {
      const v = pinEl.value.trim().toUpperCase();
      if (v.length < 4) return;
      pin = v; localStorage.setItem('jarvis-pin', v);
      veil.classList.add('hide'); check();
    };
    pinEl.addEventListener('keydown', e => { if (e.key === 'Enter') document.getElementById('ok').click(); });

    go.onclick = () => send();
    box.addEventListener('keydown', e => {
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); }
    });
    box.addEventListener('input', () => {
      box.style.height = 'auto';
      box.style.height = Math.min(box.scrollHeight, 120) + 'px';
    });

    async function check() {
      try {
        const r = await fetch('/health', { headers: { 'X-Jarvis-Pin': pin } });
        const j = await r.json();
        sub.textContent = j.ok ? 'sul Mac' : '?';
      } catch (e) { sub.textContent = 'offline'; }
    }
    check(); setInterval(check, 20000);
    bubble('jarvis', 'Ci sono. Dimmi pure.');
    </script>
    </body>
    </html>
    """
}
