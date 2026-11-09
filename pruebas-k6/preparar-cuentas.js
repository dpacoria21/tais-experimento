// Prepara un juego de cuentas para el experimento (se ejecuta una sola vez por juego).
//
//   CUENTAS=10000  -> contención baja y alta (Tabla 2)
//   CUENTAS=2      -> contención extrema
//
// Crea un libro, las cuentas y fondea cada una desde @world. Guarda los IDs en
// /datos/cuentas-<CUENTAS>.json, que lee transferencias.js.
import http from "k6/http";

const BASE = __ENV.BASE || "http://server:5001";
const API_KEY = __ENV.API_KEY || "blnk-experimento-local";
const CUENTAS = Number(__ENV.CUENTAS || 10000);
const SALDO_USD = Number(__ENV.SALDO_USD || 1000000); // por cuenta; evita rechazos por fondos
const LOTE = 50; // peticiones en paralelo por lote
const PRECISION = 100;

const params = { headers: { "X-Blnk-Key": API_KEY, "Content-Type": "application/json" }, timeout: "60s" };

export const options = {
  setupTimeout: "30m",
  scenarios: { preparar: { executor: "shared-iterations", vus: 1, iterations: 1 } },
};

// Envía un lote de POST y reintenta los que no devolvieron 201 (p. ej. 423 sobre @world).
function postLote(ruta, cuerpos) {
  let pendientes = cuerpos.map((c, i) => i);
  const respuestas = new Array(cuerpos.length);
  for (let intento = 0; pendientes.length > 0; intento++) {
    if (intento === 5) throw new Error(`${ruta}: ${pendientes.length} peticiones fallaron 5 veces`);
    const res = http.batch(pendientes.map((i) => ["POST", `${BASE}${ruta}`, JSON.stringify(cuerpos[i]), params]));
    pendientes = pendientes.filter((i, k) => {
      if (res[k].status === 201) {
        respuestas[i] = res[k].json();
        return false;
      }
      console.warn(`${ruta} -> ${res[k].status} ${String(res[k].body).slice(0, 150)}`);
      return true;
    });
  }
  return respuestas;
}

export function setup() {
  const sufijo = `${CUENTAS}c${Date.now()}`;
  const libro = postLote("/ledgers", [{ name: `experimento-${sufijo}` }])[0];

  const ids = [];
  for (let i = 0; i < CUENTAS; i += LOTE) {
    const n = Math.min(LOTE, CUENTAS - i);
    const cuerpos = [];
    for (let k = 0; k < n; k++) {
      cuerpos.push({ ledger_id: libro.ledger_id, currency: "USD", meta_data: { experimento: sufijo, indice: i + k } });
    }
    for (const b of postLote("/balances", cuerpos)) ids.push(b.balance_id);
  }

  for (let i = 0; i < ids.length; i += LOTE) {
    const cuerpos = ids.slice(i, i + LOTE).map((id) => ({
      source: "@world", destination: id, amount: SALDO_USD, precision: PRECISION, currency: "USD",
      reference: `fondeo-${sufijo}-${id}`, description: "Fondeo del experimento",
      allow_overdraft: true, skip_queue: true,
    }));
    postLote("/transactions", cuerpos);
  }

  return {
    ledger_id: libro.ledger_id,
    cuentas: ids,
    saldo_inicial_unidades: SALDO_USD * PRECISION,
    total_unidades: SALDO_USD * PRECISION * ids.length,
    creado_utc: new Date().toISOString(),
  };
}

export default function () {}

export function handleSummary(data) {
  const d = data.setup_data;
  return {
    [`/datos/cuentas-${CUENTAS}.json`]: JSON.stringify(d),
    stdout: `Juego listo: ${d.cuentas.length} cuentas en ${d.ledger_id} -> /datos/cuentas-${CUENTAS}.json\n`,
  };
}
