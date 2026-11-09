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

El comportamiento original combina colas, bloqueos Redis y control optimista. Para aislar una tecnica debes controlar las otras capas. `skip_queue=true` permite solicitar procesamiento directo; cuando uses colas, mide hasta que la transaccion quede aplicada, ademas de medir la respuesta HTTP.

En la comprobacion de esta version, la transaccion en cola genero una transaccion hija `APPLIED` con `parent_transaction` apuntando a la solicitud original; la original permanecio `QUEUED`. Correlaciona ambas y verifica los saldos al medir finalizacion. `verificacion.json` guarda los IDs de esa comprobacion. Los saldos de las cuentas de prueba se dejaron nuevamente en A=990 y B=10.

No se han cambiado las tecnicas originales: esta instalacion es el punto de partida para los experimentos.

## Despliegue

Desplegado en Dokploy (https://tais-blnk.node.scn.rest). Cada push a `main` redespliega por webhook.
