# Places a market order on the Alpaca paper trading account.
# Usage: .\place_order.ps1 -Symbol AAPL -Qty 1 -Side buy
param(
    [Parameter(Mandatory)] [string]$Symbol,
    [Parameter(Mandatory)] [int]$Qty,
    [ValidateSet("buy", "sell")] [string]$Side = "buy"
)

$base = "https://paper-api.alpaca.markets/v2"

$envFile = Join-Path $PSScriptRoot ".env"
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*([A-Z_]+)\s*=\s*(.+?)\s*$') {
            Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2]
        }
    }
}

if (-not $env:APCA_API_KEY_ID -or -not $env:APCA_API_SECRET_KEY) {
    Write-Error "Set APCA_API_KEY_ID and APCA_API_SECRET_KEY in .env first."
    exit 1
}

$headers = @{
    "APCA-API-KEY-ID"     = $env:APCA_API_KEY_ID
    "APCA-API-SECRET-KEY" = $env:APCA_API_SECRET_KEY
}

$body = @{
    symbol        = $Symbol.ToUpper()
    qty           = "$Qty"
    side          = $Side
    type          = "market"
    time_in_force = "day"
} | ConvertTo-Json

$order = Invoke-RestMethod -Method Post -Uri "$base/orders" -Headers $headers -Body $body -ContentType "application/json"
$order | Select-Object id, symbol, qty, side, type, status, submitted_at | Format-List
