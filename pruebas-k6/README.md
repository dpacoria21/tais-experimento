# Pruebas del experimento con Grafana k6

Implementan la sección 6.3 del informe: 5 estrategias × 4 niveles de hilos × 3 niveles de contención × 3 réplicas = 180 corridas en orden aleatorio, con una fila por corrida en un CSV.

| Archivo | Uso |
|---|---|
| `preparar-cuentas.js` | Crea un juego de cuentas fondeadas (10 000 y 2). Se ejecuta una vez; el runner lo llama si falta el juego. |
| `transferencias.js` | Carga de k6: transferencias concurrentes con un nivel de contención. Clasifica cada respuesta. |
| `ejecutar-experimento.ps1` | Runner: matriz, orden aleatorio, reinicio por corrida, calentamiento, medición, contadores, integridad SQL y CSV. |
| `datos/` | Juegos de cuentas (`cuentas-10000.json`, `cuentas-2.json`). Son propios de cada base de datos: no se versionan. |
| `resultados/<sesión>/` | `resultados.csv`, `sesion.json` (parámetros y semilla) y, por corrida, los resúmenes y logs de k6. |

## Cómo ejecutar

Requisitos: Docker y el laboratorio levantado (`.\experimento.ps1 iniciar`). k6 corre en el contenedor `grafana/k6:1.0.0`; no hay que instalarlo.

```powershell
.\pruebas-k6\ejecutar-experimento.ps1 -Piloto     # validar el montaje: 10 corridas cortas
.\pruebas-k6\ejecutar-experimento.ps1             # matriz completa: 180 corridas, ~3 h
```

Opciones útiles: `-Estrategias cas,wait_die`, `-Hilos 16,64`, `-Contenciones extrema`, `-Replicas 1`, `-Semilla 123` (repite el mismo orden).

### Contra el backend desplegado

```powershell
.\pruebas-k6\ejecutar-experimento.ps1 -Modo remoto -Base https://<backend> -ApiKey <clave-maestra> `
    -PgConexion "postgres://<usuario>:<clave>@<host>:5432/<base>" -Estrategias cas
```

- El runner no puede reiniciar un servidor remoto: cambia `BLNK_TRANSACTION_CONCURRENCY_STRATEGY`, vuelve a desplegar y ejecuta una estrategia por vez. Comprueba que la activa sea la indicada antes de empezar.
- El orden aleatorio queda dentro de cada estrategia, y no hay reinicio entre corridas.
- `docker stats` no llega al servidor remoto: las columnas de CPU y memoria quedan vacías; tómalas del panel de la plataforma.
- La red entre tu equipo y el servidor suma latencia: compara estrategias medidas en el mismo entorno.

## Qué responde cada medición

| Objetivo específico | Cómo se obtiene | Columnas del CSV |
|---|---|---|
| 2. Integridad de los saldos | Consultas SQL al terminar cada corrida sobre las cuentas del juego | `integridad`, `suma_esperada`, `suma_final`, `saldos_negativos`, `saldos_descuadrados`, `aplicadas_bd`, `confirmadas_coinciden` |
| 2. Ausencia de interbloqueos | Contador del detector (servidor), `pg_stat_database.deadlocks` (PostgreSQL) y peticiones sin respuesta en 60 s (k6) | `interbloqueos_detectados`, `deadlocks_postgres`, `sin_respuesta_60s` |
| 3. Throughput | Transferencias confirmadas (201) ÷ 30 s de medición | `confirmadas`, `throughput_tps` |
| 3. Tiempo de respuesta | Percentiles de k6 sobre todas las transferencias de la medición | `p50_ms`, `p95_ms`, `p99_ms`, `prom_ms`, `max_ms` |
| 3. Tasa de reintentos | Contadores del servidor: reintentos ÷ transferencias | `transferencias_servidor`, `reintentos`, `tasa_reintentos_pct`, `reintentos_agotados` |
| 3. Uso de recursos | `docker stats` del contenedor `server` durante la medición | `cpu_prom_pct`, `cpu_max_pct`, `mem_prom_mb`, `mem_max_mb`, `muestras_recursos` |
| 4. Comparación | Una fila por corrida con `estrategia`, `hilos`, `contencion` y `replica`; se promedian las réplicas | todas |

## Columnas del CSV

| Columna | Significado |
|---|---|
| `orden`, `corrida`, `fecha_utc` | Posición en el orden aleatorio, identificador (prefijo de las referencias) y hora. |
| `estrategia`, `hilos`, `contencion`, `replica` | Configuración (variable independiente, Tabla 2). |
| `enviadas` | Transferencias enviadas por k6 en la medición. |
| `confirmadas`, `throughput_tps` | Respuestas 201 y su tasa por segundo. |
| `p50_ms` … `max_ms` | Tiempo de respuesta de todas las transferencias (con o sin éxito). |
| `rechazo_fondos` | 400 `TXN_INSUFFICIENT_FUNDS`. Debe ser 0: si no, la carga no está midiendo concurrencia. |
| `conflicto_version_409` | 409 `GEN_CONFLICT`: un conflicto de versión llegó al cliente. Debe ser 0 en todas las estrategias. |
| `abortadas_409` | 409 `GEN_CONCURRENCY_ABORTED`: CAS, Wait-Die o la víctima del detector agotaron los 3 s de reintentos. |
| `bloqueadas_423` | 423: solo en `original` (candado Redis sin obtener en 3 s). |
| `errores_5xx`, `otras` | Errores del servidor y respuestas no clasificadas (los primeros cuerpos quedan en `medicion.log.err`). |
| `transferencias_servidor`, `reintentos`, `tasa_reintentos_pct`, `reintentos_agotados` | Diferencia de los contadores del servidor entre el inicio y el fin de la medición. |
| `interbloqueos_detectados` | Ciclos encontrados por el detector de `no_prevention`. Debe ser 0 en las otras cuatro. |
| `deadlocks_postgres` | Errores 40P01 de PostgreSQL durante la medición. |
| `sin_respuesta_60s` | Peticiones sin respuesta en 60 s (o conexión cortada). |
| `integridad` | `CUMPLE` si la suma de saldos no cambió, ningún saldo es negativo y cada saldo coincide con sus movimientos. |
| `suma_esperada`, `suma_final` | Suma de los saldos del juego (unidades menores): debe ser igual al fondeo total. |
| `saldos_negativos`, `saldos_descuadrados` | Cuentas con saldo negativo, o cuyo saldo difiere de (recibido − enviado) o de (crédito − débito). |
| `aplicadas_bd`, `confirmadas_coinciden` | Transferencias `APPLIED` de la corrida en la base y si coinciden con las confirmadas por k6. |
| `cpu_prom_pct`, `cpu_max_pct`, `mem_prom_mb`, `mem_max_mb`, `muestras_recursos` | Uso de recursos del servidor (100 % = un núcleo). |

## Decisiones de diseño

- **Calentamiento separado.** El calentamiento y la medición son dos ejecuciones de k6; entre ambas se toma la instantánea de saldos y contadores. Así los contadores se comparan sin reiniciarlos.
- **Las transferencias en curso al terminar se esperan** (`gracefulStop`). Por eso lo confirmado en k6 debe coincidir con lo aplicado en la base de datos.
- **Fondos de sobra.** Cada cuenta empieza con USD 1 000 000 y cada transferencia mueve USD 1, para que ningún rechazo se deba a falta de fondos.
- **Zipf 0,99.** El rango 1 es la primera cuenta del juego. Origen y destino se eligen por separado y nunca coinciden.
- **Reinicio por corrida.** En modo local el servidor se recrea antes de cada corrida, aunque la estrategia no cambie, para partir del mismo estado de memoria.
