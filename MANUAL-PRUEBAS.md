# Manual de pruebas: Blnk

Este laboratorio levanta Blnk localmente para consultar cuentas, hacer transferencias y comparar variantes del manejo de concurrencia. La aplicación se compila desde la carpeta local `blnk`.

Las peticiones modifican datos reales del laboratorio. Los archivos `datos-prueba.json` describen el estado inicial de las cuentas, no sus saldos actuales.

## 1. Contenido de la carpeta

```text
tais-art/
├── MANUAL-PRUEBAS.md          este manual
├── blnk/                      código de Blnk y archivos del laboratorio
│   ├── experimento.ps1        iniciar, detener, probar y reconstruir
│   ├── compose.experimento.yaml
│   ├── blnk.experimento.json  configuración local (puerto, clave, BD, Redis)
│   ├── preparar-datos.ps1     crea un libro y dos cuentas de prueba
│   ├── datos-prueba.json      IDs de las cuentas usadas por Postman
│   ├── postman_collection.json  colección de Postman
│   ├── peticiones.http        peticiones para clientes REST de VS Code
│   └── LEEME-EXPERIMENTO.md   detalles de la instalación
├── pruebas/                   pruebas de carga concurrente
│   ├── ejecutar.ps1           orquesta la prueba y verifica saldos
│   ├── concurrencia.js        script de carga k6
│   ├── datos/                 cuentas separadas para las pruebas de carga
│   └── resultados/            informes generados por cada corrida
└── outputs/                   material de la revisión bibliográfica
```

- **`pruebas/`**: contiene las pruebas de carga. `ejecutar.ps1` lanza muchas transferencias simultáneas con k6, consulta los saldos antes y después y guarda un informe en `pruebas/resultados/`. Ver la sección 6.
- **`outputs/`**: no forma parte de la aplicación ni de las pruebas. Guarda el trabajo de la revisión de literatura del 30 de septiembre de 2026: clasificación de artículos sobre deadlocks (`deadlocks-20260930/`) y el informe del Hito 1 con sus evidencias (`resultados-20260930/`).

## 2. Ejecutar el proyecto

### 2.1. Requisitos

Necesitas Docker Desktop con el motor Linux iniciado. No necesitas instalar Go, k6 ni PostgreSQL en Windows: todo se compila y ejecuta dentro de Docker.

Comprueba Docker:

```powershell
docker version
```

Debe mostrar información del cliente y del servidor (**Server**). Si falta el servidor, abre Docker Desktop y espera a que termine de iniciar, o ejecuta:

```powershell
docker desktop start
```

### 2.2. Iniciar Blnk

Abre PowerShell en la carpeta principal:

```powershell
cd "C:\Users\diego\OneDrive\Desktop\tais-art"
.\blnk\experimento.ps1 iniciar
```

La primera vez Docker compila Blnk desde el código local; puede tardar unos minutos. Se levantan cinco contenedores:

| Contenedor | Función |
|---|---|
| `postgres` | Base de datos (PostgreSQL 16). |
| `redis` | Colas y bloqueos distribuidos. |
| `migrate` | Aplica las migraciones y termina. |
| `server` | API REST en el puerto 5001. |
| `worker` | Procesa las transacciones que entran por cola. |

### 2.3. Comprobar que funciona

```powershell
.\blnk\experimento.ps1 probar
```

Resultado esperado: `HTTP: 200`, `Worker: UP` y `Autenticacion: OK`.

### 2.4. Datos de acceso

| Dato | Valor |
|---|---|
| Versión inicial | Blnk 0.15.7 |
| API | `http://localhost:5001` |
| Autenticación | Cabecera `X-Blnk-Key: blnk-experimento-local` |
| Salud del worker | `http://localhost:5004/health` |
| Monitor del worker | `http://localhost:5004/monitoring` |
| PostgreSQL | `localhost:5434`; base `blnk`; usuario `postgres`; clave `blnk_local` |

Abrir `http://localhost:5001` en el navegador no sirve como prueba: la API necesita la cabecera de autenticación y una ruta concreta. Para empezar, usa `GET /ledgers`.

Los puertos solo escuchan en la interfaz local (`127.0.0.1`).

### 2.5. Otros comandos

| Comando | Efecto |
|---|---|
| `.\blnk\experimento.ps1 estado` | Lista los contenedores y su estado. |
| `.\blnk\experimento.ps1 logs` | Sigue los logs de `server` y `worker`. Ctrl+C deja de seguirlos; la aplicación sigue corriendo. |
| `.\blnk\experimento.ps1 detener` | Detiene los contenedores y conserva los datos. |
| `.\blnk\experimento.ps1 reconstruir` | Recompila el código y reinicia. Úsalo después de editar archivos Go. |

Detener, iniciar o reconstruir conserva la base de datos: las cuentas no vuelven a su saldo inicial.

Sin los scripts, los equivalentes son:

```powershell
docker compose -f .\blnk\compose.experimento.yaml up -d --build
docker compose -f .\blnk\compose.experimento.yaml logs --tail 100 server worker
```

## 3. Cuentas de prueba

```powershell
Get-Content .\blnk\datos-prueba.json
```

El archivo contiene un libro contable (`ledger_id`) y dos saldos en USD (`cuenta_a` y `cuenta_b`). El juego se preparó fondeando A con USD 1,000 y transfiriendo USD 10 a B: A quedó en USD 990 y B en USD 10. Consulta la API para conocer los saldos actuales.

Los montos usan precisión 100, es decir, unidades menores (centavos):

- Un `balance` de `99000` equivale a USD 990; `1000` equivale a USD 10.
- Al enviar `amount: 1` con `precision: 100` transfieres USD 1.

Para crear un juego nuevo de cuentas (A=990, B=10) sin borrar el anterior:

```powershell
.\blnk\preparar-datos.ps1 -Nuevo
```

Sin `-Nuevo`, el script solo muestra el juego existente. Con `-Nuevo` sobrescribe `blnk\datos-prueba.json` con los nuevos IDs, salvo que indiques otro archivo con `-ArchivoSalida`.

## 4. Pruebas manuales con Postman

### 4.1. Ubicación de la colección

```text
C:\Users\diego\OneDrive\Desktop\tais-art\blnk\postman_collection.json
```

### 4.2. Importar

1. Abre Postman y elige **Import**.
2. Selecciona `blnk\postman_collection.json`.
3. Aparece la colección **"Blnk - Laboratorio local"** en el panel izquierdo.

### 4.3. Variables

Las variables ya vienen dentro de la colección; no tienes que crearlas. Para verlas, haz clic en el nombre de la colección y abre la pestaña **Variables**.

| Variable | Valor | Uso |
|---|---|---|
| `base` | `http://localhost:5001` | URL de la API. |
| `api_key` | `blnk-experimento-local` | Valor de la cabecera `X-Blnk-Key`. |
| `cuenta_a` | ID de la cuenta A | Origen de las transferencias. |
| `cuenta_b` | ID de la cuenta B | Destino de las transferencias. |

Son variables de colección: funcionan aunque Postman indique "No environment". Si creas cuentas nuevas, copia sus IDs desde `datos-prueba.json` a `cuenta_a` y `cuenta_b` y guarda con Ctrl+S.

`{{$guid}}`, usado en el campo `reference`, es una variable dinámica de Postman: genera una referencia nueva en cada envío.

### 4.4. Peticiones incluidas

| Petición | Método y ruta |
|---|---|
| Listar ledgers | `GET /ledgers` |
| Listar balances | `GET /balances` |
| Listar transactions | `GET /transactions` |
| Consultar cuenta A | `GET /balances/{{cuenta_a}}` |
| Consultar cuenta B | `GET /balances/{{cuenta_b}}` |
| Transferir USD 1 de A a B (directo) | `POST /transactions` con `skip_queue: true` |
| Transferir USD 1 de A a B (cola) | `POST /transactions` con `skip_queue: false` |

### 4.5. Primera prueba

1. Comprueba que Blnk esté corriendo (sección 2.3).
2. Ejecuta **Consultar cuenta A** y **Consultar cuenta B**, y anota los saldos.
3. Ejecuta una sola vez **Transferir USD 1 de A a B (directo)**. La respuesta debe indicar estado `APPLIED`.
4. Vuelve a consultar ambas cuentas: A debe bajar 100 unidades (USD 1) y B debe subir 100.

Cada envío de una transferencia mueve dinero.

### 4.6. Transferencias por cola

- **Directa** (`skip_queue: true`): la respuesta indica `APPLIED`; consulta los saldos.
- **Por cola** (`skip_queue: false`): la respuesta `QUEUED` solo indica que el trabajo fue recibido. Espera a que el worker lo procese y consulta los saldos.
- En la versión instalada, el worker crea una transacción hija `APPLIED` cuyo campo `parent_transaction` apunta a la solicitud original; la original permanece `QUEUED`. Búscala en `GET /transactions` y consúltala con `GET /transactions/{id}`. No midas la finalización solo con el estado de la solicitud padre.
- El monitor del worker está en `http://localhost:5004/monitoring`.

También puedes usar `blnk\peticiones.http` con la extensión REST Client de VS Code.

## 5. Pruebas manuales con PowerShell

Ejecuta los bloques desde la carpeta principal y en la misma terminal, para conservar las variables.

### 5.1. Consultar saldos

```powershell
$b = Get-Content .\blnk\datos-prueba.json -Raw | ConvertFrom-Json
$hb = @{ 'X-Blnk-Key' = 'blnk-experimento-local' }
$ba = Invoke-RestMethod "$($b.api)/balances/$($b.cuenta_a)" -Headers $hb
$bb = Invoke-RestMethod "$($b.api)/balances/$($b.cuenta_b)" -Headers $hb
"A: USD $([decimal]$ba.balance / $b.precision)"
"B: USD $([decimal]$bb.balance / $b.precision)"
```

### 5.2. Transferir USD 1 directamente

```powershell
$body = @{
    source = $b.cuenta_a
    destination = $b.cuenta_b
    amount = 1
    precision = 100
    currency = 'USD'
    reference = [Guid]::NewGuid().ToString()
    description = 'Prueba manual A a B'
    skip_queue = $true
    allow_overdraft = $false
} | ConvertTo-Json

Invoke-RestMethod "$($b.api)/transactions" `
    -Method Post -Headers $hb -ContentType 'application/json' -Body $body
```

Se espera estado `APPLIED`. Repite la consulta de saldos. Para probar la cola cambia `skip_queue` a `$false`, genera una referencia nueva y sigue lo descrito en la sección 4.6.

## 6. Pruebas de carga concurrente

Estas pruebas lanzan muchas transferencias simultáneas de A a B y comprueban que los saldos finales coincidan con las transferencias confirmadas. El script descarga y ejecuta k6 1.0.0 dentro de Docker.

### 6.1. Preparar cuentas separadas

Usa un juego de cuentas distinto del de Postman, para que las pruebas manuales no alteren la verificación:

```powershell
New-Item -ItemType Directory -Path .\pruebas\datos -Force | Out-Null

.\blnk\preparar-datos.ps1 -Nuevo `
    -ArchivoSalida "$PWD\pruebas\datos\blnk.json"
```

El juego nuevo queda en A=USD 990 y B=USD 10. Para repetir desde ese punto, crea otro juego antes de cada réplica; si guardas cada uno en un archivo distinto, podrás consultar sus cuentas después.

### 6.2. Ejecutar

```powershell
.\pruebas\ejecutar.ps1 -Proyecto blnk `
    -Usuarios 5 -Solicitudes 10 -Monto 1 -Etiqueta original `
    -ArchivoDatos .\pruebas\datos\blnk.json
```

| Parámetro | Significado |
|---|---|
| `Proyecto` | `blnk`. |
| `Usuarios` | Usuarios virtuales concurrentes, entre 1 y 100. No puede superar `Solicitudes`. |
| `Solicitudes` | Total de transferencias entre todos los usuarios; no es la cantidad por usuario. |
| `Monto` | USD por transferencia; positivo y con hasta dos decimales. |
| `Etiqueta` | Nombre de la variante, por ejemplo `original`, `optimista` o `pesimista`. Solo etiqueta el informe. |
| `ArchivoDatos` | JSON con los IDs de las cuentas. Si se omite, usa `blnk\datos-prueba.json`. |

El script:

1. Comprueba que A tenga saldo para toda la carga.
2. Ejecuta k6 dentro de la red Docker del proyecto.
3. Consulta los saldos finales y los compara con las confirmaciones.
4. Guarda los resultados en `pruebas/resultados/`.

No reintenta las peticiones fallidas. Todas las transferencias usan la misma pareja A→B, por lo que hay contención sobre esas dos cuentas. Las corridas usan procesamiento directo (`skip_queue=true`): no miden la finalización por cola, aunque los bloqueos Redis y el control optimista siguen activos.

Si las diez transferencias de USD 1 se confirman y el juego empezó en 990/10, el resultado debe ser A=980 y B=20. Una segunda corrida parte de esos nuevos saldos.

### 6.3. Interpretar los informes

Cada corrida genera dos archivos en `pruebas/resultados/`, con nombre único por etiqueta y corrida:

- `*-k6.json`: métricas de k6, tasas y latencias HTTP.
- `*-verificacion.json`: cuentas usadas, saldos antes y después, conteos de respuestas, verificación y commit Git.

Para abrir la verificación más reciente:

```powershell
$ultimo = Get-ChildItem .\pruebas\resultados\*-verificacion.json |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
Get-Content $ultimo.FullName -Raw | ConvertFrom-Json | Format-List
```

| Campo | Cómo leerlo |
|---|---|
| `confirmadas` | Transferencias aplicadas reconocidas por el generador. |
| `rechazadas` | Respuestas 400, 409, 422, 423 o 429. Revisa sus cuerpos: no todas son conflictos de concurrencia. |
| `errores` | Otros errores, respuestas inesperadas o fallos de transporte. |
| `saldos_coinciden` | Los saldos observados coinciden con los calculados a partir de las confirmaciones. |
| `carga_completa` | El total clasificado coincide con las solicitudes pedidas. |
| `duracion_http_ms` | Latencias en milisegundos (mediana, p95, p99). Incluye respuestas rechazadas. |
| `transferencias_confirmadas_por_segundo` | Tasa de confirmaciones reportada por k6. |

El cálculo es:

```text
A esperada = A inicial - confirmadas × monto
B esperada = B inicial + confirmadas × monto
```

Además se exige que A no quede negativa. Esto supone que no hay comisiones ni otros movimientos simultáneos: no uses esas cuentas en Postman durante una corrida.

Si hubo rechazos y los saldos coinciden, la integridad puede ser correcta aunque no se aceptaran todas las solicitudes. Un código de salida correcto no significa aceptación del 100 %: consulta ambos conteos.

Si aparece un timeout o una respuesta 5xx, revisa los logs y los movimientos persistidos antes de repetir: el resultado de esa petición puede ser incierto. El script conserva el informe y no corrige saldos.

## 7. Pruebas funcionales adicionales

| Prueba | Procedimiento | Qué verificar |
|---|---|---|
| Consulta | Leer las dos cuentas sin mover fondos. | Saldos estables. |
| Transferencia válida | Transferir USD 1 de A a B. | A baja 1; B sube 1; la suma se mantiene. |
| Fondos insuficientes | En Postman, enviar un monto mayor que el saldo de A, sin sobregiro. | Mensaje de rechazo y saldos sin cambios. |
| Referencia repetida | Reenviar la misma petición con la misma `reference`. | Que no se aplique un segundo movimiento; registrar la respuesta. |
| Transferencias simultáneas | Ejecutar la sección 6. | Correspondencia entre confirmaciones y movimientos persistidos. |
| Procesamiento por cola | Enviar `skip_queue=false`. | Trabajo aplicado por el worker, relación padre/hija y saldos finales. |

Para explorar interbloqueos, una prueba posterior puede mezclar transferencias A→B y B→A. El generador incluido solo hace A→B; esa ampliación debe cambiar también el cálculo de saldos esperados. Para medir baja contención usa varias parejas de cuentas independientes.

## 8. Comparar técnicas de concurrencia

Primero registra la versión original. Después prepara cada variante y conserva su código y configuración. Cambiar `-Etiqueta` no modifica el algoritmo.

| Variante propuesta | Intervención |
|---|---|
| Optimista | Versiones de registros, comprobación de actualización y política de reintentos. |
| Pesimista | Bloqueos de filas, por ejemplo `SELECT ... FOR UPDATE`, con orden consistente al bloquear dos cuentas. |
| Serializable | Nivel de aislamiento y manejo de abortos de serialización. |
| Coordinación distribuida | Bloqueos Redis o coordinación mediante colas, controlando las demás capas. |

Puntos de entrada en el código:

- `blnk/internal/lock/lock.go`: bloqueos distribuidos con Redis.
- `blnk/database/balance.go`: actualización de saldos y comprobación de versiones.
- `blnk/transaction_execution.go`: ejecución de movimientos.
- `blnk/queue.go` y `blnk/cmd/workers.go`: colas y workers.

Después de editar código, reconstruye y comprueba:

```powershell
.\blnk\experimento.ps1 reconstruir
.\blnk\experimento.ps1 probar
```

Luego crea cuentas nuevas (sección 6.1) y ejecuta la misma carga con otra etiqueta:

```powershell
.\pruebas\ejecutar.ps1 -Proyecto blnk `
    -Usuarios 5 -Solicitudes 10 -Monto 1 -Etiqueta pesimista `
    -ArchivoDatos .\pruebas\datos\blnk.json
```

Para el experimento formal:

1. Mantén constantes versión de base de datos, recursos, pool de conexiones, monto, tamaño de datos y política de reintentos, salvo la variable que estudias.
2. Usa calentamiento, varias réplicas y orden alternado o aleatorio de variantes. Diez solicitudes sirven para comprobar el montaje; para interpretar percentiles necesitas más observaciones.
3. Conserva código, imagen construida, configuración, registros de error y resultados. El informe guarda el commit y la lista de cambios Git; eso no equivale a una copia completa de la variante.
4. Registra por separado rendimiento, rechazos e integridad. No concluyas que una técnica mejora si acelera a costa de perder movimientos.

El generador comprueba cambios de saldos y detecta desajustes con las confirmaciones. Una evaluación contable completa debe revisar también asientos, identificadores, duplicados y resultados persistidos de operaciones con errores.

## 9. Problemas frecuentes

| Síntoma | Acción |
|---|---|
| Docker no encuentra el motor | Inicia Docker Desktop y revisa la sección Server de `docker version`. |
| Error de conexión en Postman | Blnk no está corriendo: ejecuta `.\blnk\experimento.ps1 iniciar` y luego `probar`. |
| HTTP 401/403 | Revisa la cabecera `X-Blnk-Key`. |
| HTTP 400 | Revisa campos, tipos e IDs del cuerpo. |
| HTTP 404 al abrir la raíz | Usa una ruta concreta de la API con su cabecera. |
| Saldo cien veces mayor | Divide `balance` entre `precision`. |
| La cola recibe la petición pero no la aplica | Revisa salud y logs del worker y relaciona las transacciones padre/hija. |
| La carga se rechaza por saldo insuficiente | Crea otro juego de datos o reduce monto o solicitudes. |
| Los cambios de código no aparecen | Ejecuta `reconstruir`; reiniciar el contenedor no compila código nuevo. |
| La red Docker de k6 no existe | Inicia el proyecto con `experimento.ps1 iniciar`. |
| PowerShell bloquea un archivo `.ps1` | Usa los comandos `docker compose` de la sección 2.5, o habilita scripts según la política de tu equipo. |

## 10. Archivos y fuentes

- `blnk/LEEME-EXPERIMENTO.md`: configuración de la instalación.
- `blnk/postman_collection.json`: colección de Postman.
- `pruebas/ejecutar.ps1`: orquestación, lectura de saldos y verificación.
- `pruebas/concurrencia.js`: carga HTTP de k6.
- `pruebas/datos/`: juegos de cuentas para las pruebas de carga.
- `pruebas/resultados/`: resultados de cada corrida.
- [Código de Blnk](https://github.com/blnkfinance/blnk).
- [Concurrencia en Blnk](https://docs.blnkfinance.com/guides/concurrency).
- [Executor shared-iterations de k6](https://grafana.com/docs/k6/latest/using-k6/scenarios/executors/shared-iterations/): número total de iteraciones compartido entre usuarios virtuales.
- [Resultados de k6](https://grafana.com/docs/k6/latest/results-output/end-of-test/): resumen de métricas al finalizar.

## 11. Comprobación realizada al preparar este manual

El 26 de octubre de 2026 se ejecutó la carga incluida con dos usuarios virtuales y cuatro transferencias de USD 1:

| Confirmadas | Rechazadas | Errores | A inicial → final | B inicial → final | Coincidencia de saldos |
|---:|---:|---:|---|---|---|
| 4 | 0 | 0 | 990 → 986 | 10 → 14 | Correcta |

Esta corrida comprobó el generador y la verificación; su tamaño no permite comparar rendimiento estadísticamente. El informe está en `pruebas/resultados/` con la etiqueta `verificacion`.

Se usaron las cuentas de `pruebas/datos/blnk.json`, que quedaron en 986/14. Las cuentas de la colección de Postman se verificaron por separado y conservaron 990/10. Para seguir los ejemplos desde el punto inicial, crea otro juego como indica la sección 6.1.
