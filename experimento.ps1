param(
    [ValidateSet('iniciar','detener','estado','logs','reconstruir','probar')]
    [string]$Accion = 'estado'
)
$ErrorActionPreference = 'Stop'
$compose = Join-Path $PSScriptRoot 'compose.experimento.yaml'
if ($Accion -eq 'probar') {
    $headers = @{ 'X-Blnk-Key' = 'blnk-experimento-local' }
    $response = Invoke-WebRequest 'http://localhost:5001/ledgers' -Headers $headers -TimeoutSec 30 -UseBasicParsing
    if ($response.StatusCode -ne 200) { throw 'Blnk no respondio correctamente' }
    $worker = Invoke-RestMethod 'http://localhost:5004/health' -TimeoutSec 15
    if ($worker.status -ne 'UP') { throw 'El worker de Blnk no reporta UP' }
    [PSCustomObject]@{ Proyecto='Blnk'; HTTP=$response.StatusCode; Worker=$worker.status; API='http://localhost:5001'; Autenticacion='OK' }
    exit 0
}
switch ($Accion) {
    'iniciar' { & docker compose -f $compose up -d }
    'detener' { & docker compose -f $compose stop }
    'estado' { & docker compose -f $compose ps -a }
    'logs' { & docker compose -f $compose logs --tail 150 -f server worker }
    'reconstruir' { & docker compose -f $compose up -d --build }
}
if ($LASTEXITCODE -ne 0) { throw "Docker Compose termino con codigo $LASTEXITCODE" }
