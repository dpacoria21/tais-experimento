// Carga del experimento: transferencias concurrentes con un nivel de contención.
//
// Variables (las fija ejecutar-experimento.ps1):
//   HILOS       usuarios virtuales: 1, 4, 16 o 64. Cada uno mantiene una transferencia en curso.
//   CONTENCION  baja    = 10 000 cuentas, origen y destino uniformes
//               alta    = 10 000 cuentas, origen y destino con sesgo Zipf (ZIPF, 0,99)
//               extrema = 2 cuentas, A->B y B->A al 50 %
//   DURACION    duración de la fase (10s de calentamiento, 30s de medición).
//   CORRIDA     prefijo de las referencias; permite contar en SQL lo aplicado en la corrida.
//
// Toda transferencia va con skip_queue: true para que la procese la estrategia
// configurada en el servidor. El resumen se guarda en SALIDA (JSON).
import http from "k6/http";
import { Counter, Trend } from "k6/metrics";
import { SharedArray } from "k6/data";

const BASE = __ENV.BASE || "http://server:5001";
const API_KEY = __ENV.API_KEY || "blnk-experimento-local";
const HILOS = Number(__ENV.HILOS || 16);
const CONTENCION = __ENV.CONTENCION || "extrema";
const DURACION = __ENV.DURACION || "30s";
const CORRIDA = __ENV.CORRIDA || `prueba${Date.now()}`;
const ZIPF = Number(__ENV.ZIPF || 0.99);
const SALIDA = __ENV.SALIDA || "/salida/resumen.json";
const ARCHIVO = __ENV.CUENTAS_ARCHIVO || (CONTENCION === "extrema" ? "/datos/cuentas-2.json" : "/datos/cuentas-10000.json");

if (!["baja", "alta", "extrema"].includes(CONTENCION)) throw new Error(`CONTENCION inválida: ${CONTENCION}`);

const cuentas = new SharedArray("cuentas", () => JSON.parse(open(ARCHIVO)).cuentas);

// Distribución acumulada de Zipf: P(rango k) proporcional a 1 / k^ZIPF.
const zipfAcumulada = new SharedArray("zipf", () => {
  if (CONTENCION !== "alta") return [1];
  const n = JSON.parse(open(ARCHIVO)).cuentas.length;
  const acumulada = new Array(n);
  let suma = 0;
  for (let k = 1; k <= n; k++) {
    suma += 1 / Math.pow(k, ZIPF);
    acumulada[k - 1] = suma;
  }
  return acumulada.map((v) => v / suma);
});

export const options = {
  scenarios: {
    transferencias: {
      executor: "constant-vus",
      vus: HILOS,
      duration: DURACION,
      // Las transferencias en curso al terminar se esperan (hasta el timeout de 60 s)
      // para que lo confirmado en k6 coincida con lo aplicado en la base de datos.
      gracefulStop: "65s",
    },
  },
  summaryTrendStats: ["avg", "min", "med", "p(90)", "p(95)", "p(99)", "max"],
};

const enviadas = new Counter("enviadas");
const confirmadas = new Counter("confirmadas");
const rechazoFondos = new Counter("rechazo_fondos");
const conflictoVersion = new Counter("conflicto_version");
const abortadas = new Counter("abortadas");
const bloqueadas = new Counter("bloqueadas");
const sinRespuesta = new Counter("sin_respuesta");
const errores5xx = new Counter("errores_5xx");
const otras = new Counter("otras");
const tiempoTodas = new Trend("tiempo_respuesta", true);
const tiempoConfirmadas = new Trend("tiempo_respuesta_confirmadas", true);

function indiceUniforme() {
  return Math.floor(Math.random() * cuentas.length);
}

function indiceZipf() {
  const u = Math.random();
  let lo = 0;
  let hi = zipfAcumulada.length - 1;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (zipfAcumulada[mid] < u) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

function elegirCuentas() {
  if (CONTENCION === "extrema") return Math.random() < 0.5 ? [0, 1] : [1, 0];
  const elegir = CONTENCION === "alta" ? indiceZipf : indiceUniforme;
  const origen = elegir();
  let destino = elegir();
  while (destino === origen) destino = elegir();
  return [origen, destino];
}

const params = {
  headers: { "X-Blnk-Key": API_KEY, "Content-Type": "application/json" },
  timeout: "60s", // sin respuesta en 60 s = posible interbloqueo (Tabla 3)
  tags: { name: "POST /transactions" },
};
let avisos = 0;

export default function () {
  const [o, d] = elegirCuentas();
  const res = http.post(`${BASE}/transactions`, JSON.stringify({
    source: cuentas[o], destination: cuentas[d], amount: 1, precision: 100, currency: "USD",
    reference: `${CORRIDA}-${__VU}-${__ITER}`, description: "Transferencia del experimento",
    allow_overdraft: false, skip_queue: true,
  }), params);

  enviadas.add(1);
  if (res.status !== 0) tiempoTodas.add(res.timings.duration);

  let codigo = "";
  if (res.status !== 201 && res.status !== 0) {
    try { codigo = res.json("error_detail.code") || ""; } catch (e) { codigo = ""; }
  }

  if (res.status === 201) {
    confirmadas.add(1);
    tiempoConfirmadas.add(res.timings.duration);
  } else if (res.status === 0) {
    sinRespuesta.add(1); // timeout de 60 s o conexión cortada
  } else if (res.status === 400 && codigo === "TXN_INSUFFICIENT_FUNDS") {
    rechazoFondos.add(1);
  } else if (res.status === 409 && codigo === "GEN_CONFLICT") {
    conflictoVersion.add(1);
  } else if (res.status === 409 && codigo === "GEN_CONCURRENCY_ABORTED") {
    abortadas.add(1);
  } else if (res.status === 423) {
    bloqueadas.add(1);
  } else if (res.status >= 500) {
    errores5xx.add(1);
  } else {
    otras.add(1);
  }
  if (res.status !== 201 && avisos < 3) {
    avisos++;
    console.warn(`${res.status} ${codigo} ${String(res.body).slice(0, 200)}`);
  }
}

function contador(data, nombre) {
  const m = data.metrics[nombre];
  return m ? m.values.count : 0;
}

function tendencia(data, nombre) {
  const m = data.metrics[nombre];
  const v = m ? m.values : {};
  const r = (x) => (x === undefined ? null : Math.round(x * 100) / 100);
  return { prom: r(v.avg), min: r(v.min), p50: r(v.med), p90: r(v["p(90)"]), p95: r(v["p(95)"]), p99: r(v["p(99)"]), max: r(v.max) };
}

export function handleSummary(data) {
  const segundos = parseFloat(DURACION) * (DURACION.endsWith("m") ? 60 : 1);
  const resumen = {
    corrida: CORRIDA,
    contencion: CONTENCION,
    hilos: HILOS,
    duracion_s: segundos,
    cuentas: cuentas.length,
    zipf: CONTENCION === "alta" ? ZIPF : null,
    enviadas: contador(data, "enviadas"),
    confirmadas: contador(data, "confirmadas"),
    rechazo_fondos: contador(data, "rechazo_fondos"),
    conflicto_version: contador(data, "conflicto_version"),
    abortadas: contador(data, "abortadas"),
    bloqueadas: contador(data, "bloqueadas"),
    sin_respuesta: contador(data, "sin_respuesta"),
    errores_5xx: contador(data, "errores_5xx"),
    otras: contador(data, "otras"),
    tiempo_respuesta_ms: tendencia(data, "tiempo_respuesta"),
    tiempo_respuesta_confirmadas_ms: tendencia(data, "tiempo_respuesta_confirmadas"),
  };
  resumen.throughput_tps = Math.round((resumen.confirmadas / segundos) * 100) / 100;
  const t = resumen.tiempo_respuesta_ms;
  return {
    [SALIDA]: JSON.stringify(resumen, null, 2),
    stdout: `${CORRIDA}: ${resumen.confirmadas}/${resumen.enviadas} confirmadas, ${resumen.throughput_tps} tps, p50=${t.p50} ms, p95=${t.p95} ms\n`,
  };
}
