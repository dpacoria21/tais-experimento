# Manual de pruebas: Blnk

Este laboratorio levanta Blnk localmente para consultar cuentas, hacer transferencias y comparar variantes del manejo de concurrencia. La aplicación se compila desde la carpeta local `blnk`.

Las peticiones modifican datos reales del laboratorio. Los archivos `datos-prueba.json` describen el estado inicial de las cuentas, no sus saldos actuales.

## 1. Contenido de la carpeta

```text
tais-art/
└── blnk/                        código de Blnk y archivos del laboratorio
    ├── MANUAL-PRUEBAS.md        este manual
    ├── experimento.ps1          iniciar, detener, probar y reconstruir
    ├── compose.experimento.yaml
    ├── blnk.experimento.json    configuración local (puerto, clave, BD, Redis)
    ├── preparar-datos.ps1       crea un libro y dos cuentas de prueba
    ├── datos-prueba.json        IDs de las cuentas de prueba
    ├── postman_collection.json  colección de Postman del experimento
    ├── peticiones.http          peticiones para clientes REST de VS Code
    └── LEEME-EXPERIMENTO.md     detalles de la instalación
```

Los comandos de este manual se ejecutan desde la carpeta `tais-art`.

## 2. Ejecutar el proyecto

### 2.1. Requisitos

Necesitas Docker Desktop con el motor Linux iniciado. No necesitas instalar Go ni PostgreSQL en Windows: todo se compila y ejecuta dentro de Docker.

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
3. Aparece la colección **"Blnk - Experimento de concurrencia"** en el panel izquierdo.

Si ya habías importado una versión anterior, elimínala de Postman o reemplázala al importar: el nombre cambió.

### 4.3. Autenticación y variables

La colección envía `X-Blnk-Key: {{api_key}}` en todas las peticiones. Está configurada en la pestaña **Authorization** de la colección; cada petición la hereda.

Las variables ya vienen dentro de la colección; no tienes que crearlas. Para verlas, haz clic en el nombre de la colección y abre la pestaña **Variables**.

| Variable | Valor inicial | Uso |
|---|---|---|
| `base` | `http://localhost:5001` | URL de la API. |
| `worker_base` | `http://localhost:5004` | URL del worker. |
| `api_key` | `blnk-experimento-local` | Clave maestra. |
| `cuenta_a` | Cuenta A de `datos-prueba.json` | Origen de las transferencias. **01 Preparación** la reemplaza. |
| `cuenta_b` | Cuenta B de `datos-prueba.json` | Destino de las transferencias. **01 Preparación** la reemplaza. |

Las demás variables (`ledger_id`, `transaction_id`, `transaction_ref`, `inflight_id`, `inflight_void_id`, `ref_repetida`, etc.) empiezan vacías. Las peticiones las llenan solas con un script de su pestaña **Scripts**, así que conviene ejecutar las carpetas en orden.

Son variables de colección: funcionan aunque Postman indique "No environment". `{{$guid}}`, usado en el campo `reference`, es una variable dinámica de Postman: genera una referencia nueva en cada envío.

### 4.4. Carpetas

La colección solo contiene lo necesario para el experimento: 29 peticiones que crean saldos, mueven dinero o verifican saldos.

| Carpeta | Contenido |
|---|---|
| 00 Salud | Servidor y worker en marcha. Ejecútala antes de cada corrida. |
| 01 Preparación | Crea un ledger y las cuentas A y B, fondea A con USD 1,000 y transfiere USD 10 a B. Deja A = 990 y B = 10, igual que `preparar-datos.ps1`. |
| 02 Verificación | Consultas sin efectos: saldos de A y B (también con la cola), número de transferencias aplicadas en cada sentido, transacciones pendientes en cola y búsqueda por ID o referencia. |
| 03 Operaciones bajo prueba | Cada tipo de operación que conviene someter a concurrencia (tabla siguiente). |
| 04 Recuperación | Reprocesa transacciones atascadas en `QUEUED`. |

| Operación (03) | Resultado esperado | Qué pone a prueba bajo concurrencia |
|---|---|---|
| Transferir USD 1 de A a B (directo) | 201, `APPLIED` | Caso base: bloqueo y actualización de dos saldos. |
| Transferir USD 1 de B a A (directo) | 201, `APPLIED` | Combinada con A→B a la vez, bloquea las mismas cuentas en orden inverso: escenario de interbloqueo. |
| Transferir USD 1 de A a B (cola) | 201, `QUEUED` | Coordinación mediante Redis y el worker. |
| Referencia repetida (dos envíos) | 201 y luego 409 `TXN_DUPLICATE_REFERENCE` | Idempotencia: dos envíos simultáneos no deberían aplicarse ambos. |
| Fondos insuficientes | 400 | Varias transferencias que juntas superan el saldo no deberían dejar A en negativo. |
| Inflight: reservar, confirmar y anular | 201 y 200 | Reservas simultáneas sobre el mismo saldo. |
| Lote atómico A→B y B→A | 201 | Bloqueo de varios saldos en una sola operación. |
| Reembolsar dos veces | 201 y luego 409 `TXN_ALREADY_REFUNDED` | Dos reembolsos simultáneos del mismo movimiento no deberían aplicarse ambos. |

Postman ejecuta las peticiones **una tras otra**: sirve para comprobar que cada operación funciona y para verificar saldos, pero no genera concurrencia. Para medirla, lanza esas mismas peticiones en paralelo con una herramienta de carga, como k6 o JMeter.

### 4.5. Flujo de una réplica

1. **00 Salud**: el servidor y el worker deben responder.
2. **01 Preparación**: crea cuentas nuevas en 990/10. Sáltala si quieres usar las cuentas de `datos-prueba.json`.
3. **02 Verificación**: anota los saldos iniciales y el número de transferencias aplicadas.
4. Ejecuta la carga concurrente sobre `cuenta_a` y `cuenta_b`. Copia sus IDs desde la pestaña **Variables**.
5. **02 Verificación** otra vez: comprueba que A final = A inicial − confirmadas × monto, que B final = B inicial + confirmadas × monto y que ningún saldo sea negativo.
6. Si usaste la cola y quedan transacciones en `QUEUED`, espera al worker o ejecuta **04 Recuperación**.

Los saldos en USD aparecen en la **Console** de Postman (abajo a la izquierda), y cada consulta de saldo comprueba que no sea negativo.

Al interpretar una corrida:

- No uses las cuentas de la corrida en Postman mientras la carga está en marcha: cualquier otro movimiento altera el cálculo.
- Si hubo rechazos y los saldos coinciden, la integridad es correcta aunque no se aceptaran todas las solicitudes. Registra por separado confirmadas, rechazadas y errores.
- Los rechazos (400, 409, 422, 423 o 429) no siempre son conflictos de concurrencia: revisa el cuerpo de la respuesta.
- Si aparece un timeout o una respuesta 5xx, el resultado de esa petición es incierto. Antes de repetirla, búscala con **Obtener transacción por referencia** y revisa los logs.

Para comprobar las operaciones antes del experimento, haz clic derecho en la colección, elige **Run collection** y pulsa **Run**. Todas las peticiones deben pasar sus tests, incluidos los rechazos esperados (400 y 409). La carpeta 03 mueve dinero entre A y B, así que ejecútala sobre cuentas recién preparadas, no sobre las de una corrida que vayas a medir.

### 4.6. Primera prueba manual

1. Comprueba que Blnk esté corriendo (sección 2.3).
2. En **02 Verificación**, ejecuta **Consultar cuenta A** y **Consultar cuenta B**, y anota los saldos.
3. En **03 Operaciones**, ejecuta una sola vez **Transferir USD 1 de A a B (directo)**. La respuesta debe indicar estado `APPLIED`.
4. Vuelve a consultar ambas cuentas: A debe bajar 100 unidades (USD 1) y B debe subir 100.

Cada envío de una transferencia mueve dinero.

### 4.7. Transferencias por cola

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

Se espera estado `APPLIED`. Repite la consulta de saldos. Para probar la cola cambia `skip_queue` a `$false`, genera una referencia nueva y sigue lo descrito en la sección 4.7.

## 6. Pruebas funcionales adicionales

| Prueba | Procedimiento | Qué verificar |
|---|---|---|
| Consulta | Leer las dos cuentas sin mover fondos. | Saldos estables. |
| Transferencia válida | Transferir USD 1 de A a B. | A baja 1; B sube 1; la suma se mantiene. |
| Fondos insuficientes | En Postman, enviar un monto mayor que el saldo de A, sin sobregiro. | Mensaje de rechazo y saldos sin cambios. |
| Referencia repetida | Reenviar la misma petición con la misma `reference`. | Que no se aplique un segundo movimiento; registrar la respuesta. |
| Transferencias simultáneas | Lanzar en paralelo las operaciones de la carpeta 03 con una herramienta de carga. | Correspondencia entre confirmaciones y movimientos persistidos (carpeta 02). |
| Procesamiento por cola | Enviar `skip_queue=false`. | Trabajo aplicado por el worker, relación padre/hija y saldos finales. |

Para explorar interbloqueos, mezcla transferencias A→B y B→A en la misma carga; el saldo esperado de cada cuenta debe considerar ambos sentidos. Para medir baja contención usa varias parejas de cuentas independientes.

## 7. Comparar técnicas de concurrencia

Primero registra la versión original. Después prepara cada variante y conserva su código y configuración.

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

Luego prepara cuentas nuevas (carpeta **01 Preparación** de Postman o `.\blnk\preparar-datos.ps1 -Nuevo`), ejecuta la misma carga que con la versión original y verifica con la carpeta **02 Verificación**.

Para el experimento formal:

1. Mantén constantes versión de base de datos, recursos, pool de conexiones, monto, tamaño de datos y política de reintentos, salvo la variable que estudias.
2. Usa calentamiento, varias réplicas y orden alternado o aleatorio de variantes. Diez solicitudes sirven para comprobar el montaje; para interpretar percentiles necesitas más observaciones.
3. Conserva código, imagen construida, configuración, registros de error y resultados de cada variante.
4. Registra por separado rendimiento, rechazos e integridad. No concluyas que una técnica mejora si acelera a costa de perder movimientos.

La verificación de saldos detecta desajustes con las confirmaciones. Una evaluación contable completa debe revisar también asientos, identificadores, duplicados y resultados persistidos de operaciones con errores.

## 8. Problemas frecuentes

| Síntoma | Acción |
|---|---|
| Docker no encuentra el motor | Inicia Docker Desktop y revisa la sección Server de `docker version`. |
| Error de conexión en Postman | Blnk no está corriendo: ejecuta `.\blnk\experimento.ps1 iniciar` y luego `probar`. |
| HTTP 401/403 | Revisa la cabecera `X-Blnk-Key`. |
| HTTP 400 | Revisa campos, tipos e IDs del cuerpo. |
| HTTP 404 al abrir la raíz | Usa una ruta concreta de la API con su cabecera. |
| Saldo cien veces mayor | Divide `balance` entre `precision`. |
| La cola recibe la petición pero no la aplica | Revisa salud y logs del worker y relaciona las transacciones padre/hija. |
| Las transferencias se rechazan por saldo insuficiente | Prepara cuentas nuevas (carpeta 01) o reduce el monto o el número de solicitudes. |
| Los cambios de código no aparecen | Ejecuta `reconstruir`; reiniciar el contenedor no compila código nuevo. |
| PowerShell bloquea un archivo `.ps1` | Usa los comandos `docker compose` de la sección 2.5, o habilita scripts según la política de tu equipo. |

## 9. Archivos y fuentes

- `blnk/LEEME-EXPERIMENTO.md`: configuración de la instalación.
- `blnk/postman_collection.json`: colección de Postman del experimento.
- `blnk/preparar-datos.ps1` y `blnk/datos-prueba.json`: cuentas de prueba.
- [Código de Blnk](https://github.com/blnkfinance/blnk).
- [Concurrencia en Blnk](https://docs.blnkfinance.com/guides/concurrency).
