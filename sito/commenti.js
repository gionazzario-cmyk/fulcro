// I commenti del sito di Fulcro. Nessun login: il cancello è il codice che l'app
// mostra nella sua finestra. Tutto passa dalla stessa origine, /functions/v1/app.
(function () {
  var modulo = document.getElementById("modulo");
  if (!modulo) return;
  var lista = document.getElementById("lista");
  var stato = document.getElementById("stato");
  var invia = document.getElementById("invia");
  var inCorso = false;

  function di(c) { return (c || "").replace(/[&<>"]/g, function (k) {
    return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[k]; }); }

  function ora(iso) {
    try { return new Date(iso).toLocaleString("it-IT", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" }); }
    catch (e) { return ""; }
  }

  function dipingi(righe) {
    if (!righe.length) {
      lista.innerHTML = '<p class="nota">Nessun commento ancora. Se l\'hai installata, sei il primo.</p>';
      return;
    }
    lista.innerHTML = righe.map(function (c) {
      return '<article class="commento"><header><b>' + di(c.nome) + '</b>' +
             '<span>' + di(ora(c.scritto_il)) + '</span></header>' +
             '<p>' + di(c.testo).replace(/\n/g, "<br>") + '</p></article>';
    }).join("");
  }

  function leggi() {
    fetch("/functions/v1/app?azione=lista", { credentials: "same-origin" })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(new Error("http")); })
      .then(function (d) { if (d && d.ok && Array.isArray(d.items)) dipingi(d.items); else Promise.reject(); })
      .catch(function () {
        lista.innerHTML = '<p class="nota">I commenti non rispondono: questa copia del sito ' +
          'è ancora senza servizio (funziona solo una volta pubblicato).</p>';
      });
  }

  modulo.addEventListener("submit", function (e) {
    e.preventDefault();
    if (inCorso) return;
    var corpo = {
      nome: document.getElementById("nome").value,
      testo: document.getElementById("testo").value,
      codice: document.getElementById("codice").value.trim().toUpperCase()
    };
    if (!corpo.nome.trim() || !corpo.testo.trim()) {
      stato.textContent = "Scrivi nome e commento."; stato.className = "errore"; return;
    }
    inCorso = true; invia.disabled = true; stato.textContent = "Invio…"; stato.className = "";
    fetch("/functions/v1/app?azione=aggiungi", {
      method: "POST",
      credentials: "same-origin",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(corpo)
    }).then(function (r) {
      return r.json().then(function (d) { return { ok: r.ok, d: d }; });
    }).then(function (x) {
      if (x.ok && x.d && x.d.scritto) {
        stato.textContent = "Pubblicato, grazie."; stato.className = "ok";
        document.getElementById("testo").value = "";
        leggi();
      } else if (x.d && x.d.error === "codice_non_valido") {
        stato.textContent = "Codice non valido: sono le 8 lettere nella finestra di Fulcro (barra laterale → Collegamenti).";
        stato.className = "errore";
      } else if (x.d && x.d.error === "testo_non_valido") {
        stato.textContent = "Il testo deve avere almeno due parole, stare sotto i 600 caratteri e non contenere link.";
        stato.className = "errore";
      } else {
        stato.textContent = "Non è partito niente: riprova tra un momento.";
        stato.className = "errore";
      }
    }).catch(function () {
      stato.textContent = "Il servizio non risponde (o sei su una copia locale senza backend).";
      stato.className = "errore";
    }).finally(function () { inCorso = false; invia.disabled = false; });
  });

  leggi();
})();
