# Dobby performance report: account value over time vs. simply holding SPY.
# Appends one row per day to logs/equity_history.csv and prints positions and
# recent copy activity. -SaveToFile also writes logs/reports/report_<date>.txt.
param([switch]$SaveToFile)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$envFile = Join-Path $root ".env"
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*([A-Z_]+)\s*=\s*(.+?)\s*$') { Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2] }
    }
}
$headers = @{ "APCA-API-KEY-ID" = $env:APCA_API_KEY_ID; "APCA-API-SECRET-KEY" = $env:APCA_API_SECRET_KEY }
$base = "https://paper-api.alpaca.markets/v2"
$inv  = [System.Globalization.CultureInfo]::InvariantCulture
$cfg = Get-Content (Join-Path $root "dobby_config.json") -Raw | ConvertFrom-Json
$logDir = Join-Path $root "logs"
New-Item -ItemType Directory -Force -Path (Join-Path $logDir "reports") | Out-Null
$histPath = Join-Path $logDir "equity_history.csv"

$acct = Invoke-RestMethod "$base/account" -Headers $headers
$positions = @(Invoke-RestMethod "$base/positions" -Headers $headers | ForEach-Object { $_ } | Where-Object { $_.symbol })
$spy = [double](Invoke-RestMethod "https://data.alpaca.markets/v2/stocks/SPY/trades/latest" -Headers $headers).trade.p
$et = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, "Eastern Standard Time")
$today = $et.ToString("yyyy-MM-dd")
$equity = [double]$acct.equity

if (-not (Test-Path $histPath)) { "date,equity,cash,spy" | Out-File $histPath -Encoding utf8 }
$hist = @(Import-Csv $histPath | Where-Object { $_.date -ne $today })
$hist += [pscustomobject]@{ date = $today; equity = $equity.ToString("0.00", $inv); cash = ([double]$acct.cash).ToString("0.00", $inv); spy = $spy.ToString("0.00", $inv) }
$hist | Export-Csv $histPath -NoTypeInformation -Encoding utf8

$first = $hist[0]
$botRet = ($equity / [double]$first.equity - 1) * 100
$spyRet = ($spy / [double]$first.spy - 1) * 100

$out = New-Object System.Collections.Generic.List[string]
$out.Add("=== Dobby report $today (copying: $(($cfg.politicians | ForEach-Object { $_.name }) -join ", ")) ===")
$out.Add(("Account value: `${0:N2}   cash: `${1:N2}" -f $equity, [double]$acct.cash))
$out.Add(("Since {0}: Dobby {1:+0.00;-0.00}%  vs  SPY {2:+0.00;-0.00}%  (edge {3:+0.00;-0.00} pts)" -f $first.date, $botRet, $spyRet, ($botRet - $spyRet)))
$out.Add("")
$out.Add("Positions:")
if ($positions.Count -eq 0) { $out.Add("  (none)") }
foreach ($p in @($positions | Sort-Object { -[double]$_.market_value })) {
    $out.Add(("  {0,-22} qty {1,10}  value `${2,10:N2}  P/L `${3,9:N2} ({4:+0.0;-0.0}%)" -f $p.symbol, $p.qty, [double]$p.market_value, [double]$p.unrealized_pl, ([double]$p.unrealized_plpc * 100)))
}
$out.Add("")
$out.Add("Recent copy activity:")
$logPath = Join-Path $logDir "copy_log.csv"
if (Test-Path $logPath) {
    foreach ($r in (Import-Csv $logPath | Select-Object -Last 15)) {
        $out.Add(("  {0}  {1,-6} {2,-20} {3,-9} {4}" -f $r.timestamp.Substring(0, 16), $r.action, $r.symbol, $r.status, $r.note))
    }
} else { $out.Add("  (no activity yet)") }

$out | ForEach-Object { Write-Host $_ }
if ($SaveToFile) { $out | Out-File (Join-Path $logDir "reports\report_$today.txt") -Encoding utf8 }
