<#
Ejecuta la matriz del experimento (seccion 6.3 del informe) y guarda una fila por corrida en
resultados\<sesion>\resultados.csv.

Por cada corrida:
  1. Configura la estrategia y reinicia el servidor (modo local).
  2. Calentamiento con k6 (se descarta).
  3. Instantanea: suma de saldos, contadores del servidor y deadlocks de PostgreSQL.
  4. Medicion con k6, muestreando CPU y memoria del servidor con docker stats (modo local).
  5. Instantanea final y consultas SQL de integridad.
  6. Fila en el CSV.

Ejemplos (desde la carpeta blnk):
  .\pruebas-k6\ejecutar-experimento.ps1 -Piloto
  .\pruebas-k6\ejecutar-experimento.ps1
  .\pruebas-k6\ejecutar-experimento.ps1 -Modo remoto -Base https://mi-blnk.ejemplo.com -ApiKey <clave> `
      -PgConexion "postgres://usuario:clave@host:5432/blnk" -Estrategias cas
#>
param(
    [ValidateSet('local', 'remoto')]
    [string]$Modo = 'local',
    [ValidateSet('original', 'global', 'ordered', 'cas', 'wait_die', 'no_prevention')]
    [string[]]$Estrategias = @('global', 'ordered', 'cas', 'wait_die', 'no_prevention'),
    [int[]]$Hilos = @(1, 4, 16, 64),
    [ValidateSet('baja', 'alta', 'extrema')]
    [string[]]$Contenciones = @('baja', 'alta', 'extrema'),
    [int]$Replicas = 3,
    [int]$CalentamientoS = 10,
    [int]$MedicionS = 30,
    # Corrida corta para validar el montaje: 16 hilos, contencion alta y extrema, 1 replica.
    [switch]$Piloto,
    # Modo remoto: URL del backend desplegado y conexion a su PostgreSQL.
    [string]$Base = '',
    [string]$ApiKey = 'blnk-experimento-local',
    [string]$PgConexion = '',
    # Semilla del orden aleatorio de las corridas (0 = al azar, queda registrada).
    [int]$Semilla = 0,
    [string]$K6Imagen = 'grafana/k6:1.0.0'
)
$ErrorActionPreference = 'Stop'
$Inv = [Globalization.CultureInfo]::InvariantCulture

$Raiz = $PSScriptRoot
$Compose = Join-Path (Split-Path $Raiz -Parent) 'compose.experimento.yaml'
$Datos = Join-Path $Raiz 'datos'
$ContenedorServidor = 'experimento-blnk-server-1'
$RedDocker = 'experimento-blnk_default'

if ($Piloto) {
    $Hilos = @(16); $Contenciones = @('alta', 'extrema'); $Replicas = 1; $CalentamientoS = 5; $MedicionS = 10
}
if ($Modo -eq 'local') {
    $BaseHost = 'http://localhost:5001'   # desde Windows
    $BaseK6 = 'http://server:5001'        # desde el contenedor de k6
} else {
    if (-not $Base -or -not $PgConexion) { throw 'Modo remoto: indica -Base y -PgConexion.' }
    if ($Estrategias.Count -ne 1) { throw 'Modo remoto: indica una sola -Estrategias (la activa en el servidor); cambiala y vuelve a ejecutar para la siguiente.' }
    $BaseHost = $Base.TrimEnd('/'); $BaseK6 = $BaseHost
}
$Headers = @{ 'X-Blnk-Key' = $ApiKey }

# --- utilidades -------------------------------------------------------------

function Num($x) { if ($null -eq $x) { return '' }; return ([double]$x).ToString('0.###', $Inv) }

# Ejecuta un programa externo sin que su salida de error detenga el script (PowerShell 5.1).
function Invoke-Nativo([string]$Exe, [string[]]$Argumentos) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $salida = & $Exe @Argumentos 2>&1 | ForEach-Object { "$_" }; $codigo = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    [PSCustomObject]@{ Codigo = $codigo; Salida = ($salida -join "`n") }
}

# Consulta SQL de una sola linea; devuelve las columnas separadas por '|'.
function Invoke-Sql([string]$Consulta) {
    if ($Modo -eq 'local') {
        $a = @('compose', '-f', $Compose, 'exec', '-T', 'postgres', 'psql', '-U', 'postgres', '-d', 'blnk', '-At', '-F', '|', '-c', $Consulta)
    } else {
        $a = @('run', '--rm', 'postgres:16', 'psql', $PgConexion, '-At', '-F', '|', '-c', $Consulta)
    }
    $r = Invoke-Nativo 'docker' $a
    if ($r.Codigo -ne 0) { throw "Consulta SQL fallida: $($r.Salida)" }
    return ($r.Salida -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1).Trim()
}

function Get-Contadores { Invoke-RestMethod "$BaseHost/concurrency/counters" -Headers $Headers -TimeoutSec 15 }

function Wait-Estrategia([string]$Estrategia, [int]$Segundos = 120) {
    $limite = (Get-Date).AddSeconds($Segundos)
    while ((Get-Date) -lt $limite) {
        try { if ((Get-Contadores).strategy -eq $Estrategia) { return } } catch { }
        Start-Sleep -Seconds 1
    }
    throw "El servidor no respondio con la estrategia $Estrategia."
}

# Paso 1: estrategia y reinicio. En remoto solo se comprueba la activa.
function Set-Estrategia([string]$Estrategia) {
    if ($Modo -eq 'remoto') {
        $activa = (Get-Contadores).strategy
        if ($activa -ne $Estrategia) { throw "El servidor remoto usa '$activa', no '$Estrategia'. Cambia BLNK_TRANSACTION_CONCURRENCY_STRATEGY y vuelve a desplegar." }
        return
    }
    $env:ESTRATEGIA = $Estrategia
    $r = Invoke-Nativo 'docker' @('compose', '-f', $Compose, 'up', '-d', '--no-deps', '--force-recreate', 'server')
    if ($r.Codigo -ne 0) { throw "No se pudo reiniciar el servidor: $($r.Salida)" }
    Wait-Estrategia $Estrategia
}

function Format-Argumentos([string[]]$a) {
    ($a | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
}

function Get-ArgumentosK6([string]$Script, [hashtable]$Variables, [string]$DirSalida) {
    $a = @('run', '--rm')
    if ($Modo -eq 'local') { $a += @('--network', $RedDocker) }
    $a += @('-v', "${Raiz}:/pruebas:ro", '-v', "${Datos}:/datos", '-v', "${DirSalida}:/salida")
    foreach ($k in $Variables.Keys) { $a += @('-e', "$k=$($Variables[$k])") }
    $a += @('-e', "BASE=$BaseK6", '-e', "API_KEY=$ApiKey", $K6Imagen, 'run', '--quiet', "/pruebas/$Script")
    return $a
}

# Ejecuta k6; en modo local muestrea docker stats del servidor mientras corre.
function Invoke-K6([string]$Script, [hashtable]$Variables, [string]$DirSalida, [string]$Log, [switch]$Muestrear) {
    $a = Get-ArgumentosK6 $Script $Variables $DirSalida
    $p = Start-Process -FilePath 'docker' -ArgumentList (Format-Argumentos $a) -NoNewWindow -PassThru `
        -RedirectStandardOutput $Log -RedirectStandardError "$Log.err"
    $null = $p.Handle
    $muestras = New-Object System.Collections.Generic.List[object]
    while (-not $p.HasExited) {
        if ($Muestrear -and $Modo -eq 'local') {
            $s = Invoke-Nativo 'docker' @('stats', '--no-stream', '--format', '{{.CPUPerc}};{{.MemUsage}}', $ContenedorServidor)
            if ($s.Codigo -eq 0 -and $s.Salida -match '([\d.]+)%;\s*([\d.]+)\s*([KMG]i?B)') {
                $mem = [double]::Parse($Matches[2], $Inv)
                switch -Regex ($Matches[3]) { '^K' { $mem = $mem / 1024 } '^G' { $mem = $mem * 1024 } }
                $muestras.Add([PSCustomObject]@{ Cpu = [double]::Parse($Matches[1], $Inv); MemMB = $mem })
            }
        } else { Start-Sleep -Milliseconds 500 }
    }
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { Write-Warning "k6 termino con codigo $($p.ExitCode); revisa $Log.err" }
    return $muestras
}

# --- consultas SQL (solo comillas simples: PowerShell 5.1 altera las dobles) ---

function Get-Instantanea([string]$Ledger) {
    $f = (Invoke-Sql ("SELECT (SELECT COALESCE(SUM(balance),0) FROM blnk.balances WHERE ledger_id = '$Ledger'), " +
        "(SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()), " +
        "to_char(now() AT TIME ZONE 'UTC' - interval '10 minutes', 'YYYY-MM-DD HH24:MI:SS')")) -split '\|'
    [PSCustomObject]@{ Suma = [decimal]::Parse($f[0], $Inv); DeadlocksPg = [long]$f[1]; Desde = $f[2] }
}

# Integridad (Tabla 3): suma total, saldos negativos y saldos que no coinciden con sus movimientos
# (suma de transferencias APPLIED recibidas menos enviadas, y balance = credito - debito).
function Get-Integridad([string]$Ledger, [string]$Corrida, [string]$Desde) {
    $sql = "WITH c AS (SELECT balance_id, balance, credit_balance, debit_balance FROM blnk.balances WHERE ledger_id = '$Ledger'), " +
        "mov AS (SELECT t.destination AS id, t.precise_amount AS m FROM blnk.transactions t JOIN c ON c.balance_id = t.destination WHERE t.status = 'APPLIED' " +
        "UNION ALL SELECT t.source, -t.precise_amount FROM blnk.transactions t JOIN c ON c.balance_id = t.source WHERE t.status = 'APPLIED'), " +
        "neto AS (SELECT id, SUM(m) AS m FROM mov GROUP BY id) " +
        "SELECT (SELECT COALESCE(SUM(balance),0) FROM c), (SELECT COUNT(*) FROM c WHERE balance < 0), " +
        "(SELECT COUNT(*) FROM c LEFT JOIN neto n ON n.id = c.balance_id WHERE c.balance <> COALESCE(n.m,0) OR c.balance <> c.credit_balance - c.debit_balance), " +
        "(SELECT COUNT(*) FROM blnk.transactions WHERE created_at >= '$Desde' AND reference LIKE '$Corrida-%' AND status = 'APPLIED'), " +
        "(SELECT deadlocks FROM pg_stat_database WHERE datname = current_database())"
    $f = (Invoke-Sql $sql) -split '\|'
    [PSCustomObject]@{
        Suma = [decimal]::Parse($f[0], $Inv); Negativos = [long]$f[1]; Descuadrados = [long]$f[2]
        AplicadasBd = [long]$f[3]; DeadlocksPg = [long]$f[4]
    }
}

# --- preparacion -----------------------------------------------------------

New-Item -ItemType Directory -Force $Datos | Out-Null
foreach ($n in @(10000, 2)) {
    $archivo = Join-Path $Datos "cuentas-$n.json"
    if (-not (Test-Path $archivo)) {
        Write-Output "Preparando el juego de $n cuentas (una sola vez)..."
        $null = Invoke-K6 'preparar-cuentas.js' @{ CUENTAS = $n } $Datos (Join-Path $Datos "preparar-$n.log")
        if (-not (Test-Path $archivo)) { throw "No se creo $archivo; revisa $Datos\preparar-$n.log.err" }
    }
}
$Juegos = @{
    'baja'    = Get-Content (Join-Path $Datos 'cuentas-10000.json') -Raw | ConvertFrom-Json
    'alta'    = Get-Content (Join-Path $Datos 'cuentas-10000.json') -Raw | ConvertFrom-Json
    'extrema' = Get-Content (Join-Path $Datos 'cuentas-2.json') -Raw | ConvertFrom-Json
}

# --- matriz y orden aleatorio ---------------------------------------------

if ($Semilla -eq 0) { $Semilla = Get-Random -Minimum 1 -Maximum 1000000 }
$null = Get-Random -SetSeed $Semilla
$configuraciones = foreach ($e in $Estrategias) { foreach ($h in $Hilos) { foreach ($c in $Contenciones) {
    foreach ($r in 1..$Replicas) { [PSCustomObject]@{ Estrategia = $e; Hilos = $h; Contencion = $c; Replica = $r } } } } }
$orden = @($configuraciones | ForEach-Object { [PSCustomObject]@{ Clave = (Get-Random); Conf = $_ } } | Sort-Object Clave | ForEach-Object { $_.Conf })

$sesion = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$etiqueta = if ($Piloto) { "piloto-$sesion" } else { $sesion }
$DirSesion = Join-Path (Join-Path $Raiz 'resultados') $etiqueta
New-Item -ItemType Directory -Force $DirSesion | Out-Null
$Csv = Join-Path $DirSesion 'resultados.csv'
[PSCustomObject]@{
    sesion = $etiqueta; modo = $Modo; semilla = $Semilla; estrategias = $Estrategias; hilos = $Hilos
    contenciones = $Contenciones; replicas = $Replicas; calentamiento_s = $CalentamientoS; medicion_s = $MedicionS
    base = $BaseHost; k6 = $K6Imagen; corridas = $orden.Count
} | ConvertTo-Json | Set-Content (Join-Path $DirSesion 'sesion.json') -Encoding UTF8

Write-Output "Sesion $etiqueta : $($orden.Count) corridas (semilla $Semilla). Resultados en $Csv"

# --- corridas ----------------------------------------------------------------

$i = 0
foreach ($conf in $orden) {
    $i++
    $corrida = 'e{0}r{1:000}' -f ($sesion -replace '-', ''), $i
    $juego = $Juegos[$conf.Contencion]
    $dir = Join-Path $DirSesion $corrida
    New-Item -ItemType Directory -Force $dir | Out-Null
    Write-Output ("[{0}/{1}] {2} | {3} hilos | contencion {4} | replica {5}" -f $i, $orden.Count, $conf.Estrategia, $conf.Hilos, $conf.Contencion, $conf.Replica)

    # 1. Estrategia y reinicio
    Set-Estrategia $conf.Estrategia

    # 2. Calentamiento (se descarta). Su prefijo no empieza como el de la medicion,
    #    para que el conteo de aplicadas en SQL (LIKE '<corrida>-%') no lo incluya.
    $vars = @{ HILOS = $conf.Hilos; CONTENCION = $conf.Contencion }
    $null = Invoke-K6 'transferencias.js' ($vars + @{ DURACION = "${CalentamientoS}s"; CORRIDA = "cal$corrida"; SALIDA = '/salida/calentamiento.json' }) $dir (Join-Path $dir 'calentamiento.log')

    # 3. Instantanea inicial
    $antes = Get-Instantanea $juego.ledger_id
    $cAntes = Get-Contadores

    # 4. Medicion
    $muestras = Invoke-K6 'transferencias.js' ($vars + @{ DURACION = "${MedicionS}s"; CORRIDA = $corrida; SALIDA = '/salida/medicion.json' }) $dir (Join-Path $dir 'medicion.log') -Muestrear

    # 5. Instantanea final e integridad
    $cDespues = Get-Contadores
    $integ = Get-Integridad $juego.ledger_id $corrida $antes.Desde
    $k6 = Get-Content (Join-Path $dir 'medicion.json') -Raw | ConvertFrom-Json

    $transferencias = $cDespues.transfers - $cAntes.transfers
    $reintentos = $cDespues.retries - $cAntes.retries
    $tasa = if ($transferencias -gt 0) { 100.0 * $reintentos / $transferencias } else { $null }
    $integridad = ($integ.Suma -eq [decimal]$juego.total_unidades) -and ($integ.Suma -eq $antes.Suma) -and ($integ.Negativos -eq 0) -and ($integ.Descuadrados -eq 0)
    $cpu = $muestras | Measure-Object -Property Cpu -Average -Maximum
    $mem = $muestras | Measure-Object -Property MemMB -Average -Maximum
    $t = $k6.tiempo_respuesta_ms

    # 6. Fila del CSV (decimales con punto)
    [PSCustomObject][ordered]@{
        orden = $i; corrida = $corrida; fecha_utc = (Get-Date).ToUniversalTime().ToString('o')
        estrategia = $conf.Estrategia; hilos = $conf.Hilos; contencion = $conf.Contencion; replica = $conf.Replica
        enviadas = $k6.enviadas; confirmadas = $k6.confirmadas; throughput_tps = Num $k6.throughput_tps
        p50_ms = Num $t.p50; p95_ms = Num $t.p95; p99_ms = Num $t.p99; prom_ms = Num $t.prom; max_ms = Num $t.max
        rechazo_fondos = $k6.rechazo_fondos; conflicto_version_409 = $k6.conflicto_version; abortadas_409 = $k6.abortadas
        bloqueadas_423 = $k6.bloqueadas; errores_5xx = $k6.errores_5xx; otras = $k6.otras
        transferencias_servidor = $transferencias; reintentos = $reintentos; tasa_reintentos_pct = Num $tasa
        reintentos_agotados = $cDespues.retries_exhausted - $cAntes.retries_exhausted
        interbloqueos_detectados = $cDespues.deadlocks_detected - $cAntes.deadlocks_detected
        deadlocks_postgres = $integ.DeadlocksPg - $antes.DeadlocksPg
        sin_respuesta_60s = $k6.sin_respuesta
        integridad = $(if ($integridad) { 'CUMPLE' } else { 'NO CUMPLE' })
        suma_esperada = $juego.total_unidades; suma_final = $integ.Suma
        saldos_negativos = $integ.Negativos; saldos_descuadrados = $integ.Descuadrados
        aplicadas_bd = $integ.AplicadasBd; confirmadas_coinciden = $(if ($integ.AplicadasBd -eq $k6.confirmadas) { 'SI' } else { 'NO' })
        cpu_prom_pct = Num $cpu.Average; cpu_max_pct = Num $cpu.Maximum; mem_prom_mb = Num $mem.Average; mem_max_mb = Num $mem.Maximum
        muestras_recursos = $muestras.Count
    } | Export-Csv -Path $Csv -Append -NoTypeInformation -Encoding UTF8

    Write-Output ("    {0} tps | p50 {1} ms | p95 {2} ms | reintentos {3} | interbloqueos {4} | integridad {5}" -f `
        (Num $k6.throughput_tps), (Num $t.p50), (Num $t.p95), $reintentos, ($cDespues.deadlocks_detected - $cAntes.deadlocks_detected), $(if ($integridad) { 'CUMPLE' } else { 'NO CUMPLE' }))
    if ($k6.rechazo_fondos -gt 0) { Write-Warning "    $($k6.rechazo_fondos) rechazos por fondos insuficientes: aumenta SALDO_USD y prepara cuentas nuevas." }
}

if ($Modo -eq 'local') { $env:ESTRATEGIA = 'original'; $null = Invoke-Nativo 'docker' @('compose', '-f', $Compose, 'up', '-d', '--no-deps', '--force-recreate', 'server') }
Write-Output "Listo: $Csv"
