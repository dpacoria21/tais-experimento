"""Gráficos de líneas de los resultados de k6 (una línea por estrategia, eje X = hilos).

Uso (desde esta carpeta, con el entorno activado):
    python graficos.py
    python graficos.py --csv ../pruebas-k6/resultados/local-contencion-alta.csv
    python graficos.py --csv ../pruebas-k6/resultados/<sesion>/resultados.csv --entorno remoto

Por defecto lee los resultados del servidor desplegado
(../pruebas-k6/resultados/remoto-contencion-alta.csv). Con varias réplicas por
punto dibuja el promedio y una banda con el mínimo y el máximo.

Salida en salida/<entorno>-<contencion>/:
    01-throughput.png ... 07-interbloqueos.png   un gráfico por métrica
    00-panel.png                                 4 métricas principales juntas
y salida/resumen-<entorno>.csv con los valores que se dibujaron.
"""
import argparse
from pathlib import Path

import matplotlib

matplotlib.use("Agg")  # sin ventana: solo guarda archivos
import matplotlib.pyplot as plt
import pandas as pd
from matplotlib.lines import Line2D
from matplotlib.ticker import FixedLocator, FuncFormatter, NullLocator

AQUI = Path(__file__).resolve().parent
CSV_POR_DEFECTO = AQUI.parent / "pruebas-k6" / "resultados" / "remoto-contencion-alta.csv"

# Cada estrategia tiene siempre el mismo color y marcador, en todos los gráficos.
# Paleta categórica validada para daltonismo; el marcador distinto también sirve
# para distinguirlas impresas en blanco y negro.
ESTRATEGIAS = {
    "global": ("Global (mutex único)", "#2a78d6", "o"),
    "ordered": ("Orden de recursos", "#eb6834", "s"),
    "cas": ("CAS (optimista)", "#1baf7a", "^"),
    "wait_die": ("Wait-Die", "#eda100", "D"),
    "no_prevention": ("Sin prevención (detector)", "#e87ba4", "v"),
    "original": ("Original (Redis)", "#008300", "P"),
}

# columna, título, etiqueta del eje Y, archivo
METRICAS = [
    ("throughput_tps", "Throughput", "Transferencias confirmadas por segundo", "01-throughput"),
    ("p50_ms", "Latencia p50", "Tiempo de respuesta p50 (ms)", "02-latencia-p50"),
    ("p95_ms", "Latencia p95", "Tiempo de respuesta p95 (ms)", "03-latencia-p95"),
    ("p99_ms", "Latencia p99", "Tiempo de respuesta p99 (ms)", "04-latencia-p99"),
    ("tasa_reintentos_pct", "Reintentos", "Reintentos por cada 100 transferencias", "05-reintentos"),
    ("tasa_fallidas_pct", "Transferencias no confirmadas", "No confirmadas (% de enviadas)", "06-no-confirmadas"),
    ("interbloqueos_detectados", "Interbloqueos detectados", "Interbloqueos en 30 s", "07-interbloqueos"),
]
PANEL = ["throughput_tps", "p95_ms", "tasa_reintentos_pct", "tasa_fallidas_pct"]

ENTORNOS = {"remoto": "Servidor desplegado", "local": "Docker local"}
CONTENCIONES = {"baja": "contención baja", "alta": "contención alta", "extrema": "contención extrema"}

# Estilo: superficie blanca, texto oscuro, rejilla fina y discreta.
TEXTO, TEXTO_2, REJILLA = "#0b0b0b", "#52514e", "#e4e3df"
plt.rcParams.update({
    "figure.facecolor": "white", "axes.facecolor": "white", "savefig.facecolor": "white",
    "font.size": 10, "axes.edgecolor": REJILLA, "axes.labelcolor": TEXTO_2,
    "xtick.color": TEXTO_2, "ytick.color": TEXTO_2, "text.color": TEXTO,
    "axes.spines.top": False, "axes.spines.right": False,
})


def cargar(rutas, entorno):
    tablas = []
    for ruta in rutas:
        t = pd.read_csv(ruta, encoding="utf-8-sig")
        if "entorno" not in t.columns:  # CSV de una sesión, sin columna de entorno
            t.insert(0, "entorno", entorno)
        tablas.append(t)
    datos = pd.concat(tablas, ignore_index=True)
    # No confirmadas: abortadas (409), bloqueadas (423), errores 5xx, sin respuesta, etc.
    datos["tasa_fallidas_pct"] = 100 * (datos["enviadas"] - datos["confirmadas"]) / datos["enviadas"]
    return datos


def resumir(datos):
    """Promedio, mínimo y máximo por entorno, contención, estrategia e hilos."""
    columnas = [m[0] for m in METRICAS]
    claves = ["entorno", "contencion", "estrategia", "hilos"]
    g = datos.groupby(claves)[columnas].agg(["mean", "min", "max"])
    g.columns = [f"{c}_{e}".replace("_mean", "") for c, e in g.columns]
    g["replicas"] = datos.groupby(claves).size()
    return g.reset_index()


def numero(v, _=None):
    """Miles separados por espacio; decimales solo en valores pequeños."""
    if abs(v) >= 1000:
        return f"{v:,.0f}".replace(",", " ")
    return f"{v:.2f}".rstrip("0").rstrip(".") if v != int(v) else f"{v:.0f}"


def estrategias_en(tabla):
    presentes = set(tabla["estrategia"])
    return [e for e in ESTRATEGIAS if e in presentes]  # siempre en el mismo orden


def dibujar_metrica(ax, tabla, columna, etiqueta_y):
    for estrategia in estrategias_en(tabla):
        nombre, color, marcador = ESTRATEGIAS[estrategia]
        s = tabla[tabla["estrategia"] == estrategia].sort_values("hilos")
        x = s["hilos"]
        if (s["replicas"] > 1).any():  # banda mínimo-máximo entre réplicas
            ax.fill_between(x, s[f"{columna}_min"], s[f"{columna}_max"], color=color, alpha=0.10, linewidth=0)
        ax.plot(x, s[columna], color=color, linewidth=1.8, solid_joinstyle="round", solid_capstyle="round",
                marker=marcador, markersize=6.5, markeredgecolor="white", markeredgewidth=1.2, label=nombre,
                zorder=3)

    hilos = sorted(tabla["hilos"].unique())
    ax.set_xscale("log", base=2)
    ax.xaxis.set_major_locator(FixedLocator(hilos))
    ax.xaxis.set_minor_locator(NullLocator())
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
    ax.set_xlim(hilos[0] / 1.35, hilos[-1] * 1.35)
    ax.set_ylim(bottom=0)
    ax.yaxis.set_major_formatter(FuncFormatter(numero))
    ax.grid(axis="y", color=REJILLA, linewidth=0.8)
    ax.set_axisbelow(True)
    ax.tick_params(length=0, pad=6)
    ax.set_xlabel("Hilos (usuarios virtuales de k6)")
    ax.set_ylabel(etiqueta_y)


def leyenda(fig, tabla, y, columnas=None):
    manejadores = []
    for e in estrategias_en(tabla):
        nombre, color, marcador = ESTRATEGIAS[e]
        manejadores.append(Line2D([], [], color=color, linewidth=1.8, marker=marcador, markersize=6.5,
                                  markeredgecolor="white", markeredgewidth=1.2, label=nombre))
    fig.legend(handles=manejadores, loc="upper left", bbox_to_anchor=(0.012, y), ncol=columnas or len(manejadores),
               frameon=False, handlelength=2.2, columnspacing=1.4, fontsize=9)


def subtitulo(entorno, contencion, tabla):
    r = tabla["replicas"]
    reps = f"{r.min()} réplica" + ("s" if r.min() > 1 else "") if r.min() == r.max() else f"{r.min()}–{r.max()} réplicas"
    base = f"{ENTORNOS.get(entorno, entorno)} · {CONTENCIONES.get(contencion, contencion)} · 30 s por corrida · {reps}"
    return base + (" (promedio y rango)" if r.max() > 1 else "")


def graficos(resumen, salida):
    archivos = []
    for (entorno, contencion), tabla in resumen.groupby(["entorno", "contencion"]):
        carpeta = salida / f"{entorno}-{contencion}"
        carpeta.mkdir(parents=True, exist_ok=True)
        sub = subtitulo(entorno, contencion, tabla)

        for columna, titulo, etiqueta_y, archivo in METRICAS:
            fig, ax = plt.subplots(figsize=(8, 4.8))
            fig.subplots_adjust(left=0.1, right=0.97, top=0.74, bottom=0.13)
            dibujar_metrica(ax, tabla, columna, etiqueta_y)
            fig.text(0.012, 0.965, f"{titulo} según el número de hilos", fontsize=13, fontweight="bold", va="top")
            fig.text(0.012, 0.905, sub, fontsize=9, color=TEXTO_2, va="top")
            leyenda(fig, tabla, 0.875, columnas=3)
            ruta = carpeta / f"{archivo}.png"
            fig.savefig(ruta, dpi=200)
            plt.close(fig)
            archivos.append(ruta)

        fig, ejes = plt.subplots(2, 2, figsize=(11, 8))
        fig.subplots_adjust(left=0.075, right=0.98, top=0.83, bottom=0.07, hspace=0.38, wspace=0.22)
        titulos = {m[0]: (m[1], m[2]) for m in METRICAS}
        for ax, columna in zip(ejes.flat, PANEL):
            titulo, etiqueta_y = titulos[columna]
            dibujar_metrica(ax, tabla, columna, etiqueta_y)
            ax.set_title(titulo, loc="left", fontsize=11, fontweight="bold", pad=10)
        fig.text(0.012, 0.975, "Estrategias de concurrencia según el número de hilos", fontsize=14,
                 fontweight="bold", va="top")
        fig.text(0.012, 0.94, sub, fontsize=9.5, color=TEXTO_2, va="top")
        leyenda(fig, tabla, 0.925)
        ruta = carpeta / "00-panel.png"
        fig.savefig(ruta, dpi=200)
        plt.close(fig)
        archivos.append(ruta)
    return archivos


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--csv", action="append", type=Path, help="CSV de resultados (se puede repetir)")
    p.add_argument("--entorno", default="remoto", help="entorno para CSV sin columna 'entorno' (remoto o local)")
    p.add_argument("--salida", type=Path, default=AQUI / "salida", help="carpeta de salida")
    a = p.parse_args()

    rutas = a.csv or [CSV_POR_DEFECTO]
    datos = cargar(rutas, a.entorno)
    resumen = resumir(datos)

    a.salida.mkdir(parents=True, exist_ok=True)
    for entorno, tabla in resumen.groupby("entorno"):
        ruta = a.salida / f"resumen-{entorno}.csv"
        tabla.round(2).to_csv(ruta, index=False, encoding="utf-8-sig")
        print(f"tabla   {ruta.relative_to(AQUI) if ruta.is_relative_to(AQUI) else ruta}")
    for ruta in graficos(resumen, a.salida):
        print(f"gráfico {ruta.relative_to(AQUI) if ruta.is_relative_to(AQUI) else ruta}")
    print(f"{len(datos)} corridas leídas de {len(rutas)} archivo(s)")


if __name__ == "__main__":
    main()
