// I commenti del sito di Fulcro.
//
// Due regole volute da chi ha fatto l'app:
// 1) **non serve un login**, ma scrive solo chi ha l'app in mano: il modulo chiede il
//    CODICE che Fulcro mostra nella card "Collegamenti" (otto caratteri, generato la
//    prima volta che l'app si avvia su quel Mac). Non è una parete crittografica: è
//    abbastanza perché un commento lo scriva uno che l'ha installata, e su una pagina
//    pubblica la differenza la fa.
// 2) niente link nel testo: una casella pubblica aperta a tutti diventa in due giorni
//    una bacheca di spam, e qui non c'è nessuno che la pulisce.
//
// I record sono pubblici e non modificabili da chi li scrive: la policy della tabella
// concede SELECT e INSERT, non UPDATE né DELETE.

const json = (body, status = 200, headers = {}) => Response.json(body, {
  status,
  headers: { "cache-control": "no-store", ...headers },
});

const CODICE = /^[A-HJ-NP-Z2-9]{8}$/;          // senza O/0, I/1: si copiano a voce
const PAGINA = 20;
const MAX_NOME = 24;
const MAX_TESTO = 600;

function pulitoTesto(testo) {
  const ripulito = String(testo).replace(/\r/g, "").trim();
  if (ripulito.length < 4 || ripulito.length > MAX_TESTO) return null;
  // un link, anche scritto male, non passa
  if (/https?:|www\.|\.site|\.com\/|\.it\/|t\.co|discord\.gg/i.test(ripulito)) return null;
  if (/(.)\1{14,}/.test(ripulito)) return null;                 // "aaaaaaaaaaaaaaa..."
  const parole = ripulito.split(/\s+/).filter(Boolean).length;
  if (parole < 2) return null;
  return ripulito;
}

function pulitoNome(nome) {
  const ripulito = String(nome ?? "").trim().slice(0, MAX_NOME);
  if (ripulito.length < 2) return null;
  if (/[<>{}\[\]`$\\]/.test(ripulito)) return null;
  return ripulito;
}

export async function handleComments({ request, supabase }) {
  const url = new URL(request.url);
  const params = url.searchParams;
  const azione = params.get("azione");
  const metodo = request.method;

  try {
    // ---------- lista pubblica ----------
    if ((azione === "lista" || azione === "nuovi") && metodo !== "GET") {
      return json({ error: "metodo_non_permesso" }, 405, { allow: "GET" });
    }
    if (azione === "lista") {
      const grezzo = params.get("offset") ?? "0";
      if (!/^(0|[1-9][0-9]{0,4})$/.test(grezzo)) return json({ error: "offset_non_valido" }, 400);
      const offset = Number(grezzo);
      const { data, error } = await supabase.from("commenti")
        .select("id,nome,testo,scritto_il")
        .eq("valido", true)
        .order("scritto_il", { ascending: false })
        .order("id", { ascending: false })
        .range(offset, offset + PAGINA);
      if (error || !Array.isArray(data)) return json({ error: "banco_non_risponde" }, 503);
      const oltre = data.length > PAGINA;
      return json({ ok: true, items: data.slice(0, PAGINA), oltre,
                    prossimo: oltre ? offset + PAGINA : null });
    }

    // ---------- ne ho letti N: il mio Jarvis chiede "cosa c'è di nuovo" ----------
    if (azione === "nuovi") {
      const dopo = params.get("dopo");
      let ricerca = supabase.from("commenti").select("id,nome,testo,scritto_il").eq("valido", true);
      if (dopo && !/^\d{4}-\d{2}-\d{2}([T ].*)?$/.test(dopo)) return json({ error: "data_non_valida" }, 400);
      if (dopo) ricerca = ricerca.gt("scritto_il", dopo);
      const { data, error } = await ricerca.order("scritto_il", { ascending: false }).range(0, PAGINA);
      if (error || !Array.isArray(data)) return json({ error: "banco_non_risponde" }, 503);
      return json({ ok: true, items: data });
    }

    // ---------- se ne scrive uno ----------
    if (azione === "aggiungi" && metodo !== "POST") {
      return json({ error: "metodo_non_permesso" }, 405, { allow: "POST" });
    }
    if (azione === "aggiungi") {
      const tipo = request.headers.get("content-type") || "";
      if (!tipo.includes("application/json")) return json({ error: "serve_json" }, 415);
      const corpo = await request.json().catch(() => null);
      if (!corpo || typeof corpo !== "object") return json({ error: "corpo_non_valido" }, 400);

      const nome = pulitoNome(corpo.nome);
      if (!nome) return json({ error: "nome_non_valido" }, 400);
      const testo = pulitoTesto(corpo.testo);
      if (!testo) return json({ error: "testo_non_valido" }, 400,
        { "x-motivo": "il testo deve stare tra 2 parole e 600 caratteri e non contenere link" });
      if (!CODICE.test(String(corpo.codice ?? "").toUpperCase())) {
        return json({ error: "codice_non_valido" }, 403,
          { "x-motivo": "il codice di 8 lettere è nella finestra di Fulcro, card Collegamenti" });
      }

      const { error } = await supabase.from("commenti").insert({
        id: crypto.randomUUID(),
        nome, testo,
        codice: String(corpo.codice).toUpperCase(),
        scritto_il: new Date().toISOString(),
        valido: true,
      });
      if (error) return json({ error: "banco_non_risponde" }, 503);
      return json({ ok: true, scritto: true }, 201);
    }

    if (metodo !== "GET" && metodo !== "POST") return json({ error: "metodo_non_permesso" }, 405, { allow: "GET, POST" });
    return json({ error: "non_trovato" }, 404);
  } catch {
    // niente errori del provider in faccia a chi scrive
    return json({ error: "banco_non_risponde" }, 503);
  }
}
