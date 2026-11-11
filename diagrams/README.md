# Gráficos de los resultados

Gráficos de líneas hechos con Python (pandas + matplotlib) a partir de los CSV de `pruebas-k6/resultados/`. Cada gráfico tiene una línea por estrategia, con los hilos (1, 4, 16, 64) en el eje X.

## Preparar el entorno (una vez)

```powershell
cd blnk\diagrams
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt
```

## Generar

```powershell
.venv\Scripts\python graficos.py
```

Por defecto usa los resultados del servidor desplegado (`../pruebas-k6/resultados/remoto-contencion-alta.csv`). Para usar otro CSV:

```powershell
.venv\Scripts\python graficos.py --csv ..\pruebas-k6\resultados\local-contencion-alta.csv
.venv\Scripts\python graficos.py --csv ..\pruebas-k6\resultados\<sesion>\resultados.csv --entorno remoto
```

`--csv` se puede repetir para juntar varias sesiones. Con más de una réplica por punto, la línea es el promedio y la banda clara va del mínimo al máximo.

## Salida

En `salida/<entorno>-<contencion>/`:

| Archivo | Métrica |
|---|---|
| `00-panel.png` | Throughput, latencia p95, reintentos y no confirmadas juntos |
| `01-throughput.png` | Transferencias confirmadas por segundo |
| `02-latencia-p50.png` … `04-latencia-p99.png` | Tiempo de respuesta p50, p95 y p99 (ms) |
| `05-reintentos.png` | Reintentos por cada 100 transferencias |
| `06-no-confirmadas.png` | % de enviadas que no terminaron en 201 (409, 423, 5xx, sin respuesta) |
| `07-interbloqueos.png` | Interbloqueos detectados por el servidor en los 30 s |

`salida/resumen-<entorno>.csv` tiene los valores dibujados (promedio, mínimo y máximo por punto), para citarlos en tablas.

Cada estrategia tiene siempre el mismo color y marcador. Los marcadores distintos permiten distinguirlas aunque el informe se imprima en blanco y negro.
