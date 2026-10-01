# Stacy -- one staggered trade with a hard floor, a ladder-in and a trailing floor,
# in an Alpaca PAPER account.
#
# Rules (dollar amounts are fixed from account equity when the trade opens):
#   Entry     buy entryPctOfEquity% of equity in whole shares at market.
#   Floor     a GTC stop order sells everything if the total loss reaches
#             stopLossPctOfEquity% of equity (1% = $100 on $10,000).
#   Ladder    once, if the first lot is down ladderLossPctOfEquity% ($50), buy
#             ladderSizeOfEntry (half) as many shares again, then move the floor
#             so the TOTAL loss on all shares is still capped at $100.
#   Trailing  once the open profit reaches trailActivatePctOfEquity% ($200), the
#             floor moves to trailPct% below the price; after that, every further
#             trailStepPct% climb moves it up again. The floor never goes down.
#
# The stop order lives at Alpaca, so the floor is enforced between runs. A stop
# becomes a market order when hit, so a fast drop or a gap can lose a bit more
# than the floor. SAFETY: orders only ever go to the paper endpoint.

param(
    # Show what would happen, but never submit orders or change state.
    [switch]$DryRun,
    # Print the rules, levels, open orders and position, then exit.
    [switch]$Summary
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

# ---------- Load .env ----------
$envFile = Join-Path $root ".env"
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*([A-Z_]+)\s*=\s*(.+?)\s*$') {
            Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2]
        }
    }
}
if (-not $env:APCA_API_KEY_ID -or -not $env:APCA_API_SECRET_KEY) {
    Write-Error "Set APCA_API_KEY_ID and APCA_API_SECRET_KEY in Stacy/.env first."
    exit 1
}
$headers = @{
    "APCA-API-KEY-ID"     = $env:APCA_API_KEY_ID
    "APCA-API-SECRET-KEY" = $env:APCA_API_SECRET_KEY
}

$cfg = Get-Content (Join-Path $root "stacy_config.json") -Raw | ConvertFrom-Json
if ($cfg.mode -ne "paper") { Write-Error "Stacy only supports mode=paper."; exit 1 }
$tradingBase = "https://paper-api.alpaca.markets/v2"
$dataBase    = "https://data.alpaca.markets/v2"
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$sym = $cfg.symbol

# ---------- Paths ----------
$stateDir = Join-Path $root "state"
$logDir   = Join-Path $root "logs"
New-Item -ItemType Directory -Force -Path $stateDir, $logDir | Out-Null
$statePath = Join-Path $stateDir "stacy_state.json"
$logPath   = Join-Path $logDir "stacy_log.csv"

# ---------- Helpers ----------
function Alpaca($method, $path, $body) {
    $req = @{ Method = $method; Uri = "$tradingBase$path"; Headers = $headers }
    if ($body) { $req.Body = ($body | ConvertTo-Json); $req.ContentType = "application/json" }
    return Invoke-RestMethod @req
}

function Fmt($n) { return ([double]$n).ToString("0.00", $inv) }
function CentsUp($n)   { return [math]::Ceiling([double]$n * 100) / 100 }
function CentsDown($n) { return [math]::Floor([double]$n * 100) / 100 }

function Write-Event($event, $qty, $price, $floor, $orderId, $note) {
    $ts = [DateTime]::UtcNow.ToString("o")
    $note = "$note" -replace '"', "'"
    $line = "$ts,$event,$qty,$(if ($price) { Fmt $price }),$(if ($floor) { Fmt $floor }),$orderId,`"$note`""
    Write-Host $line
    if ($DryRun) { return }
    if (-not (Test-Path $logPath)) { Set-Content -Path $logPath -Value "time,event,qty,price,floor,orderId,note" }
    Add-Content -Path $logPath -Value $line
}

function Save-State {
    if (-not $DryRun) { $state | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding utf8 }
}

function Get-LastPrice {
    $t = Invoke-RestMethod -Uri "$dataBase/stocks/$sym/trades/latest?feed=iex" -Headers $headers
    return [double]$t.trade.p
}

function Get-Position {
    try { return Alpaca GET "/positions/$sym" } catch { return $null }
}

function Wait-Order($id) {
    for ($i = 0; $i -lt 15; $i++) {
        $o = Alpaca GET "/orders/$id"
        if ($o.status -in @("filled", "canceled", "expired", "rejected")) { return $o }
        Start-Sleep -Seconds 2
    }
    return $o
}

# PowerShell 5.1 turns an empty JSON array into one empty item, so keep only real orders.
function Get-OpenOrders {
    return @(Alpaca GET "/orders?status=open&symbols=$sym" | ForEach-Object { $_ } | Where-Object { $_.id })
}

function Cancel-OpenOrders {
    foreach ($o in Get-OpenOrders) { try { Alpaca DELETE "/orders/$($o.id)" | Out-Null } catch {} }
    for ($i = 0; $i -lt 10 -and (Get-OpenOrders).Count -gt 0; $i++) { Start-Sleep -Seconds 1 }
}

function Submit-Market($side, $qty) {
    $o = Alpaca POST "/orders" @{ symbol = $sym; qty = "$qty"; side = $side; type = "market"; time_in_force = "day" }
    return Wait-Order $o.id
}

function Place-Stop($qty, $stopPrice) {
    $o = Alpaca POST "/orders" @{ symbol = $sym; qty = "$qty"; side = "sell"; type = "stop"; stop_price = (Fmt $stopPrice); time_in_force = "gtc" }
    $state.stopOrderId = $o.id
    return $o
}

function Sell-All($reason) {
    Cancel-OpenOrders
    $pos = Get-Position
    if ($pos) {
        $o = Submit-Market "sell" ([int]$pos.qty)
        Write-Event "SELL_ALL" $o.filled_qty $o.filled_avg_price $state.floor $o.id $reason
    }
    $state.phase = "closed"
    $state.closedReason = $reason
}

# ---------- State ----------
if (Test-Path $statePath) {
    $state = Get-Content $statePath -Raw | ConvertFrom-Json
} else {
    $state = [pscustomobject]@{
        phase = "pending_entry"; symbol = $sym
        setupEquity = $null; stopLossUSD = $null; ladderLossUSD = $null; trailActivateUSD = $null
        entryOrderId = $null; entryQty = $null; entryPrice = $null
        ladderPrice = $null; ladderQty = $null; ladderDone = $false; ladderFillPrice = $null
        floor = $null; stopOrderId = $null
        trailingActive = $false; trailAnchor = $null
        closedReason = $null
    }
}

# ---------- Summary ----------
if ($Summary) {
    $acct = Alpaca GET "/account"
    $eq = if ($state.setupEquity) { [double]$state.setupEquity } else { [double]$acct.equity }
    $px = Get-LastPrice
    Write-Host "=== Stacy: $sym (paper) ==="
    Write-Host "Phase: $($state.phase)    Account equity now: `$$(Fmt $acct.equity)    Last $sym trade: `$$(Fmt $px)"
    Write-Host ""
    Write-Host "Rules (based on `$$(Fmt $eq) equity):"
    Write-Host "  Entry     buy $($cfg.entryPctOfEquity)% of equity = ~`$$(Fmt ($eq * $cfg.entryPctOfEquity / 100)) in whole shares at market"
    Write-Host "  Floor     sell everything if total loss reaches `$$(Fmt ($eq * $cfg.stopLossPctOfEquity / 100))"
    Write-Host "  Ladder    once, at a `$$(Fmt ($eq * $cfg.ladderLossPctOfEquity / 100)) loss on the first lot, buy $($cfg.ladderSizeOfEntry * 100)% more shares; floor re-set so total loss still caps at `$$(Fmt ($eq * $cfg.stopLossPctOfEquity / 100))"
    Write-Host "  Trailing  at `$$(Fmt ($eq * $cfg.trailActivatePctOfEquity / 100)) profit, floor -> $($cfg.trailPct)% below price; again after each further +$($cfg.trailStepPct)%; never down"
    Write-Host ""
    if ($state.entryPrice) {
        Write-Host "Levels:"
        Write-Host "  Entry      $($state.entryQty) sh @ `$$(Fmt $state.entryPrice)"
        Write-Host "  Floor      `$$(Fmt $state.floor)"
        if (-not $state.ladderDone) { Write-Host "  Ladder at  `$$(Fmt $state.ladderPrice) (buy $($state.ladderQty) sh)" }
        else { Write-Host "  Ladder     done: $($state.ladderQty) sh @ `$$(Fmt $state.ladderFillPrice)" }
        if ($state.trailingActive) { Write-Host "  Trailing   active; next step when price >= `$$(Fmt ($state.trailAnchor * (1 + $cfg.trailStepPct / 100)))" }
        else {
            $q = [int]$state.entryQty
            Write-Host "  Trailing   starts when open profit >= `$$(Fmt $state.trailActivateUSD) (~`$$(Fmt ($state.entryPrice + $state.trailActivateUSD / $q)) with $q sh)"
        }
    } else {
        $q = [math]::Floor($eq * $cfg.entryPctOfEquity / 100 / $px)
        $sl = $eq * $cfg.stopLossPctOfEquity / 100
        $ll = $eq * $cfg.ladderLossPctOfEquity / 100
        $ta = $eq * $cfg.trailActivatePctOfEquity / 100
        Write-Host "Planned levels at `$$(Fmt $px) (re-computed from the actual fill):"
        Write-Host "  Entry      $q sh, ~`$$(Fmt ($q * $px))"
        Write-Host "  Floor      ~`$$(Fmt (CentsUp ($px - $sl / $q)))  ($(Fmt ($sl / $q / $px * 100))% below entry)"
        Write-Host "  Ladder at  ~`$$(Fmt ($px - $ll / $q)), buy $([math]::Floor($q * $cfg.ladderSizeOfEntry)) sh"
        Write-Host "  Trailing   starts at ~`$$(Fmt ($px + $ta / $q))"
    }
    Write-Host ""
    Write-Host "Open orders:"
    $open = Get-OpenOrders
    if ($open.Count -eq 0) { Write-Host "  (none)" }
    foreach ($o in $open) { Write-Host "  $($o.side) $($o.qty) $($o.type) stop=$($o.stop_price) tif=$($o.time_in_force) status=$($o.status) id=$($o.id)" }
    $pos = Get-Position
    Write-Host "Position: $(if ($pos) { "$($pos.qty) sh, avg `$$(Fmt $pos.avg_entry_price), P/L `$$(Fmt $pos.unrealized_pl)" } else { '(none)' })"
    exit 0
}

# ---------- Run ----------
$clock = Alpaca GET "/clock"
if (-not $clock.is_open -and -not $DryRun) { Write-Host "Market closed; nothing to do."; exit 0 }

if ($state.phase -eq "closed") { Write-Host "Trade is finished ($($state.closedReason)). Delete state/stacy_state.json to start a new one."; exit 0 }

# 1. Entry
if ($state.phase -eq "pending_entry") {
    $acct = Alpaca GET "/account"
    $eq = [double]$acct.equity
    $px = Get-LastPrice
    $qty = [int][math]::Floor($eq * $cfg.entryPctOfEquity / 100 / $px)
    $state.setupEquity      = $eq
    $state.stopLossUSD      = $eq * $cfg.stopLossPctOfEquity / 100
    $state.ladderLossUSD    = $eq * $cfg.ladderLossPctOfEquity / 100
    $state.trailActivateUSD = $eq * $cfg.trailActivatePctOfEquity / 100
    if ($DryRun) { Write-Host "DRY RUN: would buy $qty $sym at market (~`$$(Fmt ($qty * $px)))."; exit 0 }
    if (Get-Position) { Write-Error "Account already holds $sym; refusing to open a second trade."; exit 1 }
    $o = Alpaca POST "/orders" @{ symbol = $sym; qty = "$qty"; side = "buy"; type = "market"; time_in_force = "day" }
    $state.entryOrderId = $o.id
    $state.phase = "entry_submitted"
    Write-Event "ENTRY_SUBMITTED" $qty $px $null $o.id "market buy, equity $(Fmt $eq)"
    Save-State
}

# 2. Entry fill -> place the floor
if ($state.phase -eq "entry_submitted") {
    $o = Wait-Order $state.entryOrderId
    if ($o.status -eq "filled") {
        $q = [int]$o.filled_qty
        $p = [double]$o.filled_avg_price
        $state.entryQty    = $q
        $state.entryPrice  = $p
        $state.floor       = CentsUp ($p - $state.stopLossUSD / $q)
        $state.ladderPrice = $p - $state.ladderLossUSD / $q
        $state.ladderQty   = [int][math]::Floor($q * $cfg.ladderSizeOfEntry)
        $stop = Place-Stop $q $state.floor
        $state.phase = "active"
        Write-Event "ENTRY_FILLED" $q $p $state.floor $o.id "ladder at $(Fmt $state.ladderPrice)"
        Write-Event "FLOOR_PLACED" $q $null $state.floor $stop.id "GTC stop sell"
    } elseif ($o.status -in @("canceled", "expired", "rejected")) {
        Write-Event "ENTRY_FAILED" $null $null $null $o.id $o.status
        $state.phase = "pending_entry"
    } else {
        Write-Host "Entry order still $($o.status); will check next run."
    }
    Save-State
}

# 3. Manage the open trade
if ($state.phase -eq "active") {
    $pos = Get-Position
    if (-not $pos) {
        $stop = if ($state.stopOrderId) { Alpaca GET "/orders/$($state.stopOrderId)" }
        $why = if ($stop -and $stop.status -eq "filled") { "floor hit at $(Fmt $stop.filled_avg_price)" } else { "position gone" }
        Write-Event "CLOSED" $null $null $state.floor $state.stopOrderId $why
        if ($stop -and $stop.status -eq "filled") { Write-Event "SOLD" $stop.filled_qty $stop.filled_avg_price $state.floor $stop.id "stop filled" }
        Cancel-OpenOrders
        $state.phase = "closed"; $state.closedReason = $why
        Save-State
        exit 0
    }

    $px  = [double]$pos.current_price
    $upl = [double]$pos.unrealized_pl
    $qty = [int]$pos.qty
    Write-Host "$sym $qty sh @ avg $(Fmt $pos.avg_entry_price), price $(Fmt $px), P/L $(Fmt $upl), floor $(Fmt $state.floor)"

    # Backstop in case the price is already through the floor (e.g. stop missing).
    if ($upl -le -$state.stopLossUSD -or $px -le $state.floor) {
        if ($DryRun) { Write-Host "DRY RUN: would sell all ($qty sh), price at/below floor."; exit 0 }
        Sell-All "price $(Fmt $px) at/below floor $(Fmt $state.floor)"
        Save-State
        exit 0
    }

    # Ladder in, once, before trailing starts.
    if (-not $state.ladderDone -and -not $state.trailingActive -and $px -le $state.ladderPrice) {
        if ($DryRun) { Write-Host "DRY RUN: would ladder in $($state.ladderQty) sh."; exit 0 }
        # Alpaca rejects a buy while an opposite-side stop is open, so drop it briefly.
        Cancel-OpenOrders
        $o = Submit-Market "buy" $state.ladderQty
        $state.ladderDone = $true
        if ($o.status -eq "filled") {
            $state.ladderFillPrice = [double]$o.filled_avg_price
            Write-Event "LADDER_FILLED" $o.filled_qty $o.filled_avg_price $null $o.id ""
        } else {
            Write-Event "LADDER_FAILED" $state.ladderQty $null $null $o.id $o.status
        }
        $pos = Get-Position
        $qty = [int]$pos.qty
        $cost = [double]$pos.cost_basis
        # Floor so the loss on ALL shares is still capped at stopLossUSD.
        $state.floor = [math]::Max([double]$state.floor, (CentsUp (($cost - $state.stopLossUSD) / $qty)))
        $px = [double]$pos.current_price
        if ($px -le $state.floor) { Sell-All "after ladder, price $(Fmt $px) at/below floor $(Fmt $state.floor)"; Save-State; exit 0 }
        $stop = Place-Stop $qty $state.floor
        Write-Event "FLOOR_PLACED" $qty $null $state.floor $stop.id "after ladder, avg $(Fmt $pos.avg_entry_price)"
        Save-State
    }

    # Trailing floor.
    $candidate = $null
    if (-not $state.trailingActive -and $upl -ge $state.trailActivateUSD) {
        $state.trailingActive = $true
        $state.trailAnchor = $px
        $candidate = CentsDown ($px * (1 - $cfg.trailPct / 100))
        Write-Event "TRAIL_ON" $qty $px $state.floor $null "profit $(Fmt $upl); 5% below = $(Fmt $candidate)"
    } elseif ($state.trailingActive -and $px -ge $state.trailAnchor * (1 + $cfg.trailStepPct / 100)) {
        $state.trailAnchor = $px
        $candidate = CentsDown ($px * (1 - $cfg.trailPct / 100))
        Write-Event "TRAIL_STEP" $qty $px $state.floor $null "5% below = $(Fmt $candidate)"
    }
    if ($candidate -and $candidate -gt $state.floor) {
        if ($DryRun) { Write-Host "DRY RUN: would raise floor to $(Fmt $candidate)."; exit 0 }
        $state.floor = $candidate
        $new = Alpaca PATCH "/orders/$($state.stopOrderId)" @{ stop_price = (Fmt $candidate) }
        $state.stopOrderId = $new.id
        Write-Event "FLOOR_RAISED" $qty $px $state.floor $new.id ""
    }

    # Make sure the floor's stop order is still live.
    $stop = if ($state.stopOrderId) { try { Alpaca GET "/orders/$($state.stopOrderId)" } catch { $null } }
    if (-not $stop -or $stop.status -in @("canceled", "expired", "rejected", "replaced")) {
        if (-not $DryRun) {
            Cancel-OpenOrders
            $stop = Place-Stop $qty $state.floor
            Write-Event "FLOOR_PLACED" $qty $null $state.floor $stop.id "re-placed missing stop"
        }
    }
    Save-State
}
