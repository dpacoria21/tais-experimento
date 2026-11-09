# Blnk: laboratorio local

Para las pruebas paso a paso, Postman y carga concurrente consulta el [manual general de pruebas](../MANUAL-PRUEBAS.md).

Codigo oficial: https://github.com/blnkfinance/blnk

Version inicial: **v0.15.7**, commit `a127d489497ea79e76393bacb110dba7bfe5c81f`.
Rama local: `experimento-concurrencia`.

Servidor, worker y migraciones se compilan desde el codigo de ESTA carpeta usando Go 1.25 dentro de Docker. No necesitas instalar Go en Windows.

## Acceso

- API: http://localhost:5001
- Cabecera: `X-Blnk-Key: blnk-experimento-local`
- Salud del worker: http://localhost:5004/health
- Monitor de workers: http://localhost:5004/monitoring
- PostgreSQL: `localhost:5434`, base `blnk`, usuario `postgres`, clave `blnk_local`.
- Redis queda dentro de la red Docker de este proyecto.

Los puertos publicados solo escuchan en la interfaz local. Se levanta el core abierto y su API; no incluye el dashboard Enterprise.

## Comandos (PowerShell, dentro de esta carpeta)

```powershell
.\experimento.ps1 estado
.\experimento.ps1 probar
.\experimento.ps1 detener
.\experimento.ps1 iniciar
.\experimento.ps1 logs
```

Despues de editar codigo Go:

```powershell
.\experimento.ps1 reconstruir
```

Equivalente sin scripts:

```powershell
docker compose -f compose.experimento.yaml up -d --build
docker compose -f compose.experimento.yaml logs --tail 100 server worker
```

Las migraciones se ejecutan antes del servidor y el worker. PostgreSQL y Redis usan volumenes propios; detener o reconstruir conserva los datos.

## Primeras peticiones

```powershell
$headers = @{ 'X-Blnk-Key' = 'blnk-experimento-local' }
Invoke-RestMethod http://localhost:5001/ledgers -Headers $headers
Invoke-RestMethod http://localhost:5001/ledgers -Method Post -Headers $headers -ContentType 'application/json' -Body '{"name":"Laboratorio de concurrencia"}'
```

Tambien tienes `peticiones.http` para un cliente REST compatible.

Puedes importar `postman_collection.json` en Postman: incluye la clave, consultas de cuentas y transferencias directas o por cola. Las variables usan los IDs del juego inicial; actualizalas si creas otro juego. Cada envio de una transferencia mueve dinero en el laboratorio.

## Cuentas de prueba

`preparar-datos.ps1` crea un libro y dos cuentas, fondea A con USD 1,000 y transfiere USD 10 a B. Comprueba A=990 y B=10. `datos-prueba.json` guarda los IDs y los saldos iniciales en unidades menores (precision 100). Una segunda ejecucion reutiliza los IDs guardados; `-Nuevo` crea otro juego de datos sin borrar el anterior.

```powershell
.\preparar-datos.ps1
Get-Content .\datos-prueba.json
```

## Donde intervenir concurrencia

- `internal/lock/lock.go`: bloqueos distribuidos mediante Redis.
- `database/balance.go`: actualizaciones de saldos y comprobacion de versiones.
- `transaction_execution.go`: ejecucion de movimientos.
- `queue.go`, `cmd/workers.go`: colas y trabajadores.
- `blnk.experimento.json`: configuracion local.
- `internal/concurrency/`: las cinco estrategias del experimento (ver "Estrategias de concurrencia").

El comportamiento original combina colas, bloqueos Redis y control optimista. Para aislar una tecnica debes controlar las otras capas. `skip_queue=true` permite solicitar procesamiento directo; cuando uses colas, mide hasta que la transaccion quede aplicada, ademas de medir la respuesta HTTP.

En la comprobacion de esta version, la transaccion en cola genero una transaccion hija `APPLIED` con `parent_transaction` apuntando a la solicitud original; la original permanecio `QUEUED`. Correlaciona ambas y verifica los saldos al medir finalizacion. `verificacion.json` guarda los IDs de esa comprobacion. Los saldos de las cuentas de prueba se dejaron nuevamente en A=990 y B=10.

## Estrategias de concurrencia

El acceso a los dos saldos de una transferencia se decide en `executeWithLock` (`transaction_execution.go`). La estrategia se elige al iniciar, sin recompilar:

```powershell
.\experimento.ps1 iniciar -Estrategia wait_die
.\experimento.ps1 reconstruir -Estrategia cas     # despues de editar codigo Go
```

Sin `-Estrategia` se usa `original`. El log de `server` muestra la activa (`concurrency strategy`).

| Valor | Estrategia | Archivo |
|---|---|---|
| `original` | Blnk sin cambios: candados Redis con claves ordenadas, todo o nada, y control de version en SQL | `internal/lock/lock.go` |
| `global` | Bloqueo global: un unico `sync.Mutex` | `internal/concurrency/global.go` |
| `ordered` | Bloqueo por cuenta con orden total | `internal/concurrency/ordered.go` |
| `cas` | CAS sobre estado inmutable: `UPDATE ... WHERE version = v` y reintento | `internal/concurrency/cas.go` |
| `wait_die` | Wait-Die | `internal/concurrency/waitdie.go` |
| `no_prevention` | Control sin prevencion con detector de ciclos | `internal/concurrency/noprevention.go` |

Lo comun (seleccion, reintentos y candado con dueno) esta en `internal/concurrency/concurrency.go`.

- CAS, Wait-Die y la victima del detector reintentan con la misma pausa aleatoria que el candado Redis original (5 a 100 ms) durante `lock_wait_timeout` (3 s). Si no terminan, la API responde 409 `GEN_CONCURRENCY_ABORTED`.
- El detector busca un ciclo cuando un candado lleva 100 ms esperando. Cada interbloqueo detectado escribe en el log de `server` una linea `deadlock detected, victim aborted` con el total acumulado.
- Wait-Die y el detector usan un candado propio con dueno y espera cancelable: `sync.Mutex` no sabe quien lo tiene ni permite abortar una espera.
- Las dos filas de saldo se actualizan siempre en orden de `balance_id` (`database/transaction.go`). Con candados no cambia nada; en `cas` evita que A->B y B->A se interbloqueen dentro de PostgreSQL.

Para que la comparacion sea valida, envia las transferencias con `skip_queue: true` a una sola replica de `server`: las estrategias coordinan un solo proceso, y por la cola las procesa el `worker` por otro camino.
