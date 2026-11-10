// Le animazioni della pagina: niente librerie, niente rete, niente che giri per
// conto suo quando nessuno guarda. La logica è la stessa dell'app: si lavora solo
// per ciò che è in vista, e se il sistema chiede "meno movimento" non si fa nulla.
(function () {
  var doc = document.documentElement;
  var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // tutto ciò che deve arrivare: se non c'è IntersectionObserver (o se il visitatore
  // ha chiesto poche animazioni) lo mostriamo subito, fermo. Niente contenuti nascosti
  // per colpa di uno script che non parte.
  function mostraTutto() {
    var tutti = document.querySelectorAll('[data-ani]');
    for (var i = 0; i < tutti.length; i++) tutti[i].classList.add('vista');
  }

  var bersagli = [].slice.call(document.querySelectorAll('[data-ani]'));
  if (reduce || !('IntersectionObserver' in window)) {
    mostraTutto();
  } else {
    var io = new IntersectionObserver(function (entrate) {
      for (var i = 0; i < entrate.length; i++) {
        if (!entrate[i].isIntersecting) continue;
        entrate[i].target.classList.add('vista');
        io.unobserve(entrate[i].target);
      }
    }, { rootMargin: '0px 0px -10% 0px', threshold: 0.15 });

    // il ritardo scatta a gruppi di sei: una sezione alla volta, non tutta la pagina
    bersagli.forEach(function (el, i) { el.style.setProperty('--i', i % 6); io.observe(el); });
  }

  // FULCRO lettera per lettera, con la sua curva (blur + scala, dal file originale)
  var nome = document.querySelector('.nome');
  if (nome) {
    var testo = nome.textContent.trim();
    nome.textContent = '';
    for (var n = 0; n < testo.length; n++) {
      var lettera = document.createElement('span');
      lettera.textContent = testo[n];
      lettera.style.setProperty('--i', n);
      nome.appendChild(lettera);
    }
  }

  // la luce che corre sul bordo alto di ogni card, una volta sola
  [].slice.call(document.querySelectorAll('.blocco')).forEach(function (b) {
    var luce = document.createElement('i');
    luce.className = 'luce';
    b.appendChild(luce);
  });

  // i numeri che salgono: 7, 25, 1,6... (la virgola resta virgola, è italiano)
  function sali(el) {
    var scritto = el.getAttribute('data-conta');
    var target = parseFloat(scritto);
    if (isNaN(target)) return;
    var decimale = (scritto.split('.')[1] || '').length;
    var finale = decimale ? target.toFixed(decimale).replace('.', ',') : target.toFixed(0);
    // se la scheda è in secondo piano requestAnimationFrame non gira: meglio il numero
    // giusto subito che uno fermo a metà (e su una pagina che parla di misure vere,
    // un numero a metà è una bugia)
    if (reduce || document.hidden) { el.textContent = finale; return; }
    var t0 = null, durata = 900;
    function passo(ts) {
      if (t0 === null) t0 = ts;
      var p = Math.min((ts - t0) / durata, 1);
      var morbido = 1 - Math.pow(1 - p, 3);
      var valore = (target * morbido).toFixed(decimale);
      el.textContent = decimale ? valore.replace('.', ',') : valore;
      if (p < 1) requestAnimationFrame(passo);
    }
    requestAnimationFrame(passo);
    // rete: se il fotogramma si ferma (scheda nascosta dopo la partenza, throttling),
    // il numero arriva comunque al suo valore
    setTimeout(function () { el.textContent = finale; }, durata + 300);
  }
  var numeri = [].slice.call(document.querySelectorAll('[data-conta]'));
  if (numeri.length && !reduce && 'IntersectionObserver' in window) {
    var io2 = new IntersectionObserver(function (entrate) {
      for (var i = 0; i < entrate.length; i++) {
        if (!entrate[i].isIntersecting) continue;
        sali(entrate[i].target);
        io2.unobserve(entrate[i].target);
      }
    }, { threshold: 0.6 });
    numeri.forEach(function (el) { io2.observe(el); });
  }

  // l'alone dell'apertura segue il puntatore. Su touch non si mette nemmeno:
  // non c'è un puntatore da seguire, e un bagliore che insegue il dito è confuso.
  var apertura = document.querySelector('.apertura');
  var fine = window.matchMedia && window.matchMedia('(pointer:fine)').matches;
  if (apertura && !reduce && fine) {
    var alone = document.createElement('div');
    alone.className = 'alone';
    apertura.appendChild(alone);
    var x = 50, y = 32, inCorso = false;
    apertura.addEventListener('pointermove', function (e) {
      var r = apertura.getBoundingClientRect();
      x = ((e.clientX - r.left) / r.width) * 100;
      y = ((e.clientY - r.top) / r.height) * 100;
      if (inCorso) return;
      inCorso = true;
      requestAnimationFrame(function () {
        alone.style.setProperty('--x', x.toFixed(1) + '%');
        alone.style.setProperty('--y', y.toFixed(1) + '%');
        inCorso = false;
      });
    });
  }

  // i commenti entrano uno dopo l'altro: lo script dei commenti li crea, qui si
  // numerano. Se non c'è, niente: si vedono tutti insieme, che va bene lo stesso.
  var osservatoreCommenti = ('MutationObserver' in window) ? new MutationObserver(function (cambiamenti) {
    for (var i = 0; i < cambiamenti.length; i++) {
      [].slice.call(cambiamenti[i].addedNodes).forEach(function (nodo) {
        if (!nodo.querySelectorAll) return;
        [].slice.call(nodo.querySelectorAll('.commento')).forEach(function (c, ordine) {
          c.style.setProperty('--i', Math.min(ordine, 8));
        });
      });
    }
  }) : null;
  var lista = document.getElementById('lista');
  if (lista && osservatoreCommenti) osservatoreCommenti.observe(lista, { childList: true, subtree: true });

  // rete di sicurezza: se l'IntersectionObserver non batte ciglio (scheda in secondo
  // piano, browser che riprende lo scroll più tardi, un errore montante), ciò che è
  // già in schermo deve comparire lo stesso. Una pagina che resta bianca perché
  // l'animazione non è partita non è un'animazione: è un bug.
  setTimeout(function () {
    var tutti = document.querySelectorAll('[data-ani]:not(.vista)');
    for (var i = 0; i < tutti.length; i++) {
      if (tutti[i].getBoundingClientRect().top < (window.innerHeight || 800)) {
        tutti[i].classList.add('vista');
      }
    }
  }, 1200);

  // l'ultimo tocco: la pagina si "accende" dopo il primo fotogramma, così le
  // animazioni d'insieme (griglia, pulsante, scansione) non partono sul vuoto.
  // Il timeout è la stessa rete di sopra: in una scheda nascosta requestAnimationFrame
  // non gira, e senza fallback l'accensione non arriverebbe mai.
  function accendi() { document.body.classList.add('acceso'); }
  requestAnimationFrame(function () { requestAnimationFrame(accendi); });
  setTimeout(accendi, 400);
})();
