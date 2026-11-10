// Bancarella locale: finge il banco e chiama il VERO handler di functions/handler.mjs.
// Prova le regole (codice dell'app, link, lunghezze, metodi, errori del banco)
// senza toccare il cloud. I dati qui sono finti, di proposito.
import { handleComments } from "../functions/handler.mjs";

function fintaSupabase(esito = {}) {
  const catene = [];
  const nodo = {};
  const passa = (...a) => { catene.push(a); return nodo; };
  nodo.from = (t) => passa("from", t);
  nodo.select = (c) => passa("select", c);
  nodo.eq = (k, v) => passa("eq", k, v);
  nodo.gt = (k, v) => passa("gt", k, v);
  nodo.order = () => nodo;
  nodo.range = () => nodo;
  nodo.insert = async (r) => { catene.push(["insert", JSON.stringify(r)]); return { error: esito.erroreScrittura ?? null }; };
  // la catena di lettura si aspetta { data, error }
  nodo.then = (resolve) => resolve(esito.erroreLettura
    ? { data: null, error: { message: "boom del provider" } }
    : { data: esito.righe ?? [], error: null });
  return nodo;
}

const chiama = async (q, opts = {}, esito = {}) => {
  const res = await handleComments({
    request: new Request(`https://sito.example/functions/v1/app?${q}`, opts),
    supabase: fintaSupabase(esito),
  });
  return { stato: res.status, corpo: await res.json(), motivo: res.headers.get("x-motivo") };
};
const corpo = (o) => ({ method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(o) });

let falliti = 0;
const prova = (nome, ok, dettaglio = "") => {
  console.log(`  ${ok ? "ok  " : "FAIL"} ${nome}${dettaglio ? " — " + dettaglio : ""}`);
  if (!ok) falliti++;
};

const righe = [{ id: "a", nome: "gio", testo: "bello davvero", scritto_il: "2026-10-21T18:00:00Z" }];
const l = await chiama("azione=lista", {}, { righe });
prova("lista pubblica", l.stato === 200 && l.corpo.ok === true && l.corpo.items.length === 1);

const n = await chiama("azione=aggiungi", corpo({ nome: "anna", testo: "funziona bene, grazie", codice: "K7H2M9QX" }));
prova("commento valido passa", n.stato === 201 && n.corpo.scritto === true);

const senza = await chiama("azione=aggiungi", corpo({ nome: "anna", testo: "ciao ciao", codice: "" }));
prova("senza codice dell'app viene fermato", senza.stato === 403, senza.motivo || "");

const corto = await chiama("azione=aggiungi", corpo({ nome: "anna", testo: "ciao ciao", codice: "ABC" }));
prova("codice falso fermato", corto.stato === 403);

const intruso = await chiama("azione=aggiungi", corpo({ nome: "anna", testo: "guarda https://roba.example/x", codice: "K7H2M9QX" }));
prova("testo con link fermato", intruso.stato === 400);

const nomeCorto = await chiama("azione=aggiungi", corpo({ nome: "a", testo: "ciao ciao", codice: "K7H2M9QX" }));
prova("nome di una lettera fermato", nomeCorto.stato === 400);

const chilometrico = await chiama("azione=aggiungi", corpo({ nome: "anna", testo: "a".repeat(700) + " b", codice: "K7H2M9QX" }));
prova("testo oltre 600 caratteri fermato", chilometrico.stato === 400);

const cancella = await chiama("azione=cancellaTutto");
prova("azione inesistente fa 404", cancella.stato === 404);

const getSuPost = await chiama("azione=aggiungi");
prova("un GET su aggiungi non scrive: 405", getSuPost.stato === 405);
const getSuListaPost = await chiama("azione=lista", { method: "DELETE" });
prova("un DELETE sulla lista non tocca niente: 405", getSuListaPost.stato === 405);

const offset = await chiama("azione=lista&offset=-4");
prova("offset marcio fermato", offset.stato === 400);

const nuovi = await chiama("azione=nuovi&dopo=2026-10-20T00:00:00Z", {}, { righe });
prova("l'app chiede i nuovi dal suo ultimo letto", nuovi.stato === 200 && nuovi.corpo.items.length === 1);

const dataMarcia = await chiama("azione=nuovi&dopo=%3BDROP");
prova("data marcia nei nuovi fermata", dataMarcia.stato === 400);

const rotto = await chiama("azione=lista", {}, { erroreLettura: true });
prova("banco rotto = 503 e niente dettagli", rotto.stato === 503 && !JSON.stringify(rotto.corpo).includes("boom"));

console.log(falliti ? `\n${falliti} prove fallite` : "\ntutte le prove dei commenti passate");
process.exit(falliti ? 1 : 0);
