# Mason trade report.
# Reconciles today's (or -Date's) entries in logs/trade_log.csv against live
# order status from Alpaca, and reports, per executed trade:
#   1) confidence level
#   2) result (filled / partially filled / open / failed, with fill price when known)
#   3) if failed, why (Alpaca's own error/status detail, or the submit-time error we logged)
#
# Usage:
#   .\mason_report.ps1                # today's executed trades
#   .\mason_report.ps1 -Date 2026-09-27
#   .\mason_report.ps1 -All            # every executed trade in the log

param(
    # Defaults to today's Eastern Time date, even on UTC machines (e.g. GitHub Actions).
    [string]$Date = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, "Eastern Standard Time").ToString("yyyy-MM-dd"),
    [switch]$All,
    # Also save the report to logs\reports\report_<date>.txt (used by the 5 PM wrap-up task).
    [switch]$SaveToFile
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

if ($SaveToFile) {
    $reportDir = Join-Path $root "logs\reports"
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    $reportName = if ($All) { "report_all.txt" } else { "report_$Date.txt" }
    Start-Transcript -Path (Join-Path $reportDir $reportName) -Force | Out-Null
}

# ---------- Load .env ----------
$envFile = Join-Path $root ".env"
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*([A-Z_]+)\s*=\s*(.+?)\s*$') {
            Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2]
        }
    }
}
$headers = @{
    "APCA-API-KEY-ID"     = $env:APCA_API_KEY_ID
    "APCA-API-SECRET-KEY" = $env:APCA_API_SECRET_KEY
}

$configPath = Join-Path $root "strategy_config.json"
$cfg = Get-Content $configPath -Raw | ConvertFrom-Json
$tradingBase = if ($cfg.mode -eq "live") { "https://api.alpaca.markets/v2" } else { "https://paper-api.alpaca.markets/v2" }
$agentName = if ($cfg.agentName) { $cfg.agentName } else { "Agent" }

$logPath = Join-Path $root "logs\trade_log.csv"
if (-not (Test-Path $logPath)) {
    Write-Host "No trade log found yet at $logPath."
    exit 0
}

$rows = Import-Csv -Path $logPath

# Only rows where Mason actually decided to act (buy/sell), regardless of
# whether submission succeeded -- a submit failure is still a trade attempt
# and belongs in the report per (3) below.
$rows = $rows | Where-Object { $_.decision -in @("buy", "sell") -and $_.note -notlike "DRY RUN*" }

if (-not $All) {
    $rows = $rows | Where-Object { $_.timestamp -like "$Date*" }
}

if (-not $rows -or $rows.Count -eq 0) {
    Write-Host "$agentName made no trade attempts for $(if ($All) { 'the logged period' } else { $Date })."
    exit 0
}

Write-Host "=== $agentName trade report: $(if ($All) { 'all time' } else { $Date }) ===`n"

$summary = @{ filled = 0; partial = 0; open = 0; failed = 0 }

foreach ($r in $rows) {
    $confidence = $r.confidence
    $resultText = ""
    $reasonText = ""

    if ($r.note -like "LIVE mode*") {
        $resultText = "PROPOSED ONLY (live mode -- awaiting your confirmation, not submitted)"
        $summary.open++
    }
    elseif ([string]::IsNullOrWhiteSpace($r.orderId)) {
        # Submission itself threw (paper) -- the failure reason is in the log's note.
        $resultText = "FAILED (never accepted by Alpaca)"
        $reasonText = $r.note
        $summary.failed++
    } else {
        try {
            $order = Invoke-RestMethod -Uri "$tradingBase/orders/$($r.orderId)" -Headers $headers
        } catch {
            $resultText = "UNKNOWN (could not fetch order $($r.orderId): $($_.Exception.Message))"
            $summary.failed++
            $order = $null
        }

        if ($order) {
            switch ($order.status) {
                "filled" {
                    $resultText = "FILLED $($order.filled_qty) @ `$$($order.filled_avg_price)"
                    $summary.filled++
                }
                "partially_filled" {
                    $resultText = "PARTIALLY FILLED $($order.filled_qty)/$($order.qty) @ `$$($order.filled_avg_price)"
                    $summary.partial++
                }
                { $_ -in @("new","accepted","pending_new","accepted_for_bidding") } {
                    $resultText = "OPEN/PENDING (status: $($order.status))"
                    $summary.open++
                }
                { $_ -in @("canceled","expired") } {
                    $resultText = "FAILED ($($order.status))"
                    $reasonText = if ($order.canceled_at) { "Canceled at $($order.canceled_at)" } else { "Expired without filling (no counterparty within time_in_force window)" }
                    $summary.failed++
                }
                "rejected" {
                    $resultText = "FAILED (rejected)"
                    $reasonText = if ($order.PSObject.Properties.Name -contains "reject_reason" -and $order.reject_reason) {
                        $order.reject_reason
                    } else {
                        "Alpaca rejected the order (common causes: insufficient buying power, symbol not tradable, wash-trade/PDT restriction). Check the Alpaca dashboard for this order id for full detail."
                    }
                    $summary.failed++
                }
                default {
                    $resultText = "Status: $($order.status)"
                }
            }
        }
    }

    Write-Host "[$($r.timestamp)] $($r.symbol) $($r.decision) x$($r.qty)"
    Write-Host "  1) Confidence level : $confidence"
    Write-Host "  2) Result           : $resultText"
    if ($resultText -like "FAILED*") {
        Write-Host "  3) Why it failed    : $reasonText"
    }
    Write-Host ""
}

Write-Host "--- Summary ---"
Write-Host "Filled: $($summary.filled)  Partially filled: $($summary.partial)  Open/Pending: $($summary.open)  Failed: $($summary.failed)  Total attempts: $($rows.Count)"

if ($SaveToFile) { Stop-Transcript | Out-Null }
