# Checks the connection to an Alpaca paper trading account.
# Reads keys from a local .env file (or existing environment variables),
# so they never live in this script.
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

$acct = Invoke-RestMethod -Uri "$base/account" -Headers $headers
$acct | Select-Object account_number, status, currency, cash, buying_power, equity, pattern_day_trader | Format-List
