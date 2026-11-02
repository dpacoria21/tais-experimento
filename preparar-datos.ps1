param(
    [switch]$Nuevo,
    [string]$ArchivoSalida = (Join-Path $PSScriptRoot 'datos-prueba.json')
)
$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5001'
$headers = @{ 'X-Blnk-Key' = 'blnk-experimento-local' }
$file = [IO.Path]::GetFullPath($ArchivoSalida)
function Invoke-Blnk([string]$Ruta, [object]$Datos) {
    $json = $Datos | ConvertTo-Json -Depth 10
    Invoke-RestMethod "$base/$Ruta" -Method Post -Headers $headers -ContentType 'application/json' -Body $json -TimeoutSec 60
}
if ((Test-Path -LiteralPath $file) -and -not $Nuevo) {
    Write-Output 'Ya existe un juego de datos. Usa -Nuevo para crear otro.'
    Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    exit 0
}
$suffix = [Guid]::NewGuid().ToString('N').Substring(0,12)
$ledger = Invoke-Blnk 'ledgers' @{name="Laboratorio $suffix"}
$a = Invoke-Blnk 'balances' @{ledger_id=$ledger.ledger_id; currency='USD'; meta_data=@{nombre='Cuenta A'; experimento=$suffix}}
$b = Invoke-Blnk 'balances' @{ledger_id=$ledger.ledger_id; currency='USD'; meta_data=@{nombre='Cuenta B'; experimento=$suffix}}
$funding = Invoke-Blnk 'transactions' @{
    source='@world'; destination=$a.balance_id; amount=1000; precision=100; currency='USD'
    reference="fondeo-$suffix"; description='Fondeo del laboratorio'; allow_overdraft=$true; skip_queue=$true
}
$transfer = Invoke-Blnk 'transactions' @{
    source=$a.balance_id; destination=$b.balance_id; amount=10; precision=100; currency='USD'
    reference="transferencia-$suffix"; description='Verificacion inicial A a B'; allow_overdraft=$false; skip_queue=$true
}
$stateA = Invoke-RestMethod "$base/balances/$($a.balance_id)" -Headers $headers
$stateB = Invoke-RestMethod "$base/balances/$($b.balance_id)" -Headers $headers
if ([decimal]$stateA.balance -ne 99000 -or [decimal]$stateB.balance -ne 1000) {
    throw "Saldos inesperados: A=$($stateA.balance), B=$($stateB.balance)"
}
$result = [ordered]@{
    api=$base; ledger_id=$ledger.ledger_id; cuenta_a=$a.balance_id; cuenta_b=$b.balance_id
    currency='USD'; precision=100; saldo_a_unidades_menores=$stateA.balance; saldo_b_unidades_menores=$stateB.balance
    fondeo_id=$funding.transaction_id; transferencia_id=$transfer.transaction_id
    verificado_utc=[DateTime]::UtcNow.ToString('o')
}
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $file -Encoding utf8
[PSCustomObject]$result
