# Stacy -- trades one position at a time in an Alpaca PAPER account: waits for a
# candle setup, enters, then manages the trade with a hard floor, a ladder-in and
# a trailing floor. When the trade closes she goes back to scanning.
#
# Entry (all must hold, checked on completed 15-minute candles):
#   Trend     daily close above its 20-day average, and that average rising.
#   Intraday  price above today's VWAP, 9-EMA above 21-EMA, RSI(14) in range.
#   Trigger   the last 15-min candle is a bullish engulfing, a hammer, or a
#             green close above the previous 4 candles' highs (breakout).
#   Window    only between entryStartET and entryEndET, and not within
#             cooldownMinutes of the last exit.
#
# Trade rules (dollar amounts are fixed from account equity at each entry):
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
# than the floor. These are mechanical rules, not a prediction or advice.
# SAFETY: orders only ever go to the paper endpoint.

param(
    # Show what would happen, but never submit orders or change state.
    [switch]$DryRun,
    # Print the rules, levels / setup checks, open orders and position, then exit.
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
$etZone = [TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time")

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

function To-Date($s) {
    if ($s -is [DateTime]) { return $s.ToUniversalTime() }
    return [DateTime]::Parse("$s", $inv, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
}
function To-ET($utc) { return [TimeZoneInfo]::ConvertTimeFromUtc($utc, $etZone) }
function ET-Minutes($hhmm) { $p = $hhmm.Split(":"); return [int]$p[0] * 60 + [int]$p[1] }

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

function Get-LastPrice($symbol) {
    $t = Invoke-RestMethod -Uri "$dataBase/stocks/$symbol/trades/latest?feed=iex" -Headers $headers
    return [double]$t.trade.p
}

function Get-Position {
    try { return Alpaca GET "/positions/$sym" } catch { return $null }
}

function Get-AllPositions {
    return ,@(Alpaca GET "/positions" | ForEach-Object { $_ } | Where-Object { $_.symbol })
}

function Wait-Order($id) {
    for ($i = 0; $i -lt 15; $i++) {
        $o = Alpaca GET "/orders/$id"
        if ($o.status -in @("filled", "canceled", "expired", "rejected")) { return $o }
        Start-Sleep -Seconds 2
    }
    return $o
}

# PowerShell 5.1 turns an empty JSON array into one empty item, so keep only real
# items; the leading comma stops a one-item list from unrolling (and losing .Count).
function Get-OpenOrders {
    return ,@(Alpaca GET "/orders?status=open&symbols=$sym" | ForEach-Object { $_ } | Where-Object { $_.id })
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

# ---------- Candles and indicators ----------
function Get-Bars($symbol, $timeframe, $days) {
    $start = [DateTime]::UtcNow.AddDays(-$days).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $url = "$dataBase/stocks/$symbol/bars?timeframe=$timeframe&start=$start&limit=10000&feed=iex&adjustment=split"
    $bars = @((Invoke-RestMethod -Uri $url -Headers $headers).bars | Where-Object { $_.t })
    foreach ($b in $bars) { $b.t = To-Date $b.t }
    return $bars
}

function Get-Ema($values, $n) {
    $k = 2 / ($n + 1)
    $ema = $values[0]
    for ($i = 1; $i -lt $values.Count; $i++) { $ema = $values[$i] * $k + $ema * (1 - $k) }
    return $ema
}

function Get-Rsi($values, $n) {
    $gain = 0; $loss = 0
    for ($i = 1; $i -le $n; $i++) {
        $d = $values[$i] - $values[$i - 1]
        if ($d -gt 0) { $gain += $d } else { $loss -= $d }
    }
    $gain /= $n; $loss /= $n
    for ($i = $n + 1; $i -lt $values.Count; $i++) {
        $d = $values[$i] - $values[$i - 1]
        $gain = ($gain * ($n - 1) + [math]::Max($d, 0)) / $n
        $loss = ($loss * ($n - 1) + [math]::Max(-$d, 0)) / $n
    }
    if ($loss -eq 0) { return 100 }
    return 100 - 100 / (1 + $gain / $loss)
}

# Reads the charts for one symbol and says whether there's an entry right now.
function Find-Setup($symbol) {
    $r = [ordered]@{ symbol = $symbol; ok = $false; trigger = $null; checks = [ordered]@{} }
    $nowUtc = [DateTime]::UtcNow

    # Daily trend.
    $daily = @(Get-Bars $symbol "1Day" 60 | Where-Object { (To-ET $_.t).Date -lt (To-ET $nowUtc).Date })
    if ($daily.Count -lt 26) { $r.checks["data"] = "only $($daily.Count) daily candles"; return $r }
    $closes = @($daily | ForEach-Object { [double]$_.c })
    $n = $closes.Count
    $sma20     = ($closes[($n - 20)..($n - 1)] | Measure-Object -Average).Average
    $sma20Prev = ($closes[($n - 25)..($n - 6)] | Measure-Object -Average).Average
    $r.checks["daily close $(Fmt $closes[-1]) > 20-day avg $(Fmt $sma20)"] = ($closes[-1] -gt $sma20)
    $r.checks["20-day avg rising (5 days ago $(Fmt $sma20Prev))"] = ($sma20 -gt $sma20Prev)

    # Completed regular-hours 15-minute candles from the last few sessions.
    $bars = @(Get-Bars $symbol "15Min" 7 | Where-Object {
        $m = (To-ET $_.t).TimeOfDay.TotalMinutes
        $m -ge 570 -and $m -lt 960 -and $_.t.AddMinutes(15) -le $nowUtc
    })
    if ($bars.Count -lt 30) { $r.checks["data"] = "only $($bars.Count) 15-min candles"; return $r }
    $c = @($bars | ForEach-Object { [double]$_.c })
    $ema9  = Get-Ema $c 9
    $ema21 = Get-Ema $c 21
    $rsi   = Get-Rsi $c 14

    $today = (To-ET $nowUtc).Date
    $todayBars = @($bars | Where-Object { (To-ET $_.t).Date -eq $today })
    if ($todayBars.Count -lt 2) { $r.checks["data"] = "need 2 completed 15-min candles today"; return $r }
    $pv = 0; $vol = 0
    foreach ($b in $todayBars) { $pv += [double]$b.vw * [double]$b.v; $vol += [double]$b.v }
    $vwap = if ($vol -gt 0) { $pv / $vol } else { [double]$todayBars[-1].c }

    $last = $bars[-1]; $prev = $bars[-2]
    $price = [double]$last.c
    $r.price = $price
    $r.checks["price $(Fmt $price) > VWAP $(Fmt $vwap)"] = ($price -gt $vwap)
    $r.checks["9-EMA $(Fmt $ema9) > 21-EMA $(Fmt $ema21)"] = ($ema9 -gt $ema21)
    $r.checks["RSI $([math]::Round($rsi, 1)) in $($cfg.rsiMin)-$($cfg.rsiMax)"] = ($rsi -ge $cfg.rsiMin -and $rsi -le $cfg.rsiMax)

    # Candle trigger on the last completed candle.
    $o = [double]$last.o; $h = [double]$last.h; $l = [double]$last.l
    $body = [math]::Abs($price - $o)
    $lowerWick = [math]::Min($o, $price) - $l
    $upperWick = $h - [math]::Max($o, $price)
    $engulf = ([double]$prev.c -lt [double]$prev.o) -and ($price -gt $o) -and ($o -le [double]$prev.c) -and ($price -ge [double]$prev.o)
    $hammer = ($body -gt 0) -and ($lowerWick -ge 2 * $body) -and ($upperWick -le $body) -and ($l -le $ema21)
    $prior4High = (@($bars[-5..-2] | ForEach-Object { [double]$_.h }) | Measure-Object -Maximum).Maximum
    $breakout = ($price -gt $o) -and ($price -gt $prior4High)
    $r.trigger = if ($engulf) { "bullish engulfing" } elseif ($hammer) { "hammer at the 21-EMA" } elseif ($breakout) { "breakout above $(Fmt $prior4High)" } else { $null }
    $r.checks["candle trigger: $(if ($r.trigger) { $r.trigger } else { 'none' })"] = [bool]$r.trigger

    $r.ok = -not ($r.checks.Values -contains $false)
    return $r
}

function Show-Setup($s) {
    Write-Host "  $($s.symbol): $(if ($s.ok) { 'ENTRY SIGNAL' } else { 'no entry' })"
    foreach ($k in $s.checks.Keys) {
        $v = $s.checks[$k]
        $mark = if ($v -is [bool]) { if ($v) { "[x]" } else { "[ ]" } } else { "[!]" }
        Write-Host "    $mark $k$(if ($v -isnot [bool]) { ": $v" })"
    }
}

function In-EntryWindow {
    $m = (To-ET ([DateTime]::UtcNow)).TimeOfDay.TotalMinutes
    return ($m -ge (ET-Minutes $cfg.entryStartET) -and $m -lt (ET-Minutes $cfg.entryEndET))
}

# ---------- State ----------
function New-TradeState($tradeCount, $cooldownUntil) {
    return [pscustomobject]@{
        phase = "scanning"; symbol = $null; tradeCount = $tradeCount; cooldownUntil = $cooldownUntil
        setupEquity = $null; stopLossUSD = $null; ladderLossUSD = $null; trailActivateUSD = $null
        entryOrderId = $null; entryQty = $null; entryPrice = $null; entrySignal = $null
        ladderPrice = $null; ladderQty = $null; ladderDone = $false; ladderFillPrice = $null
        floor = $null; stopOrderId = $null
        trailingActive = $false; trailAnchor = $null
    }
}

function Finish-Trade($reason) {
    $count = 1 + $(if ($state.tradeCount) { [int]$state.tradeCount } else { 0 })
    Write-Event "TRADE_CLOSED" $null $null $state.floor $null "$sym trade #$count closed: $reason; back to scanning"
    $script:state = New-TradeState $count ([DateTime]::UtcNow.AddMinutes($cfg.cooldownMinutes).ToString("o"))
}

function Sell-All($reason) {
    Cancel-OpenOrders
    $pos = Get-Position
    if ($pos) {
        $o = Submit-Market "sell" ([int]$pos.qty)
        Write-Event "SELL_ALL" $o.filled_qty $o.filled_avg_price $state.floor $o.id $reason
    }
    Finish-Trade $reason
}

if (Test-Path $statePath) {
    $state = Get-Content $statePath -Raw | ConvertFrom-Json
    # Older state files: "pending_entry" / "closed" mean there's no open trade.
    if ($state.phase -in @("pending_entry", "closed")) { $state = New-TradeState $state.tradeCount $null }
    foreach ($f in @("tradeCount", "cooldownUntil", "entrySignal")) {
        if (-not ($state.PSObject.Properties.Name -contains $f)) { $state | Add-Member -NotePropertyName $f -NotePropertyValue $null }
    }
} else {
    $state = New-TradeState 0 $null
}
$sym = $state.symbol

# ---------- Summary ----------
if ($Summary) {
    $acct = Alpaca GET "/account"
    $eq = if ($state.setupEquity) { [double]$state.setupEquity } else { [double]$acct.equity }
    Write-Host "=== Stacy (paper) ==="
    Write-Host "Phase: $($state.phase)    Trades closed: $([int]$state.tradeCount)    Account equity now: `$$(Fmt $acct.equity)"
    Write-Host ""
    Write-Host "Trade rules (based on `$$(Fmt $eq) equity):"
    Write-Host "  Entry     buy $($cfg.entryPctOfEquity)% of equity = ~`$$(Fmt ($eq * $cfg.entryPctOfEquity / 100)) in whole shares at market"
    Write-Host "  Floor     sell everything if total loss reaches `$$(Fmt ($eq * $cfg.stopLossPctOfEquity / 100))"
    Write-Host "  Ladder    once, at a `$$(Fmt ($eq * $cfg.ladderLossPctOfEquity / 100)) loss on the first lot, buy $($cfg.ladderSizeOfEntry * 100)% more shares; floor re-set so total loss still caps at `$$(Fmt ($eq * $cfg.stopLossPctOfEquity / 100))"
    Write-Host "  Trailing  at `$$(Fmt ($eq * $cfg.trailActivatePctOfEquity / 100)) profit, floor -> $($cfg.trailPct)% below price; again after each further +$($cfg.trailStepPct)%; never down"
    Write-Host ""
    if ($state.phase -eq "scanning") {
        Write-Host "Scanning $($cfg.watchlist -join ', ') between $($cfg.entryStartET) and $($cfg.entryEndET) ET:"
        foreach ($s in $cfg.watchlist) { Show-Setup (Find-Setup $s) }
        if ($state.cooldownUntil) { Write-Host "  Cooldown until $((To-ET (To-Date $state.cooldownUntil)).ToString('MMM d HH:mm')) ET" }
    } elseif ($state.entryPrice) {
        Write-Host "Open trade in $sym$(if ($state.entrySignal) { " (entered on: $($state.entrySignal))" }):"
        Write-Host "  Entry      $($state.entryQty) sh @ `$$(Fmt $state.entryPrice)"
        Write-Host "  Floor      `$$(Fmt $state.floor)"
        if (-not $state.ladderDone) { Write-Host "  Ladder at  `$$(Fmt $state.ladderPrice) (buy $($state.ladderQty) sh)" }
        else { Write-Host "  Ladder     done: $($state.ladderQty) sh @ `$$(Fmt $state.ladderFillPrice)" }
        if ($state.trailingActive) { Write-Host "  Trailing   active; next step when price >= `$$(Fmt ($state.trailAnchor * (1 + $cfg.trailStepPct / 100)))" }
        else { Write-Host "  Trailing   starts when open profit >= `$$(Fmt $state.trailActivateUSD)" }
    }
    Write-Host ""
    if ($sym) {
        Write-Host "Open orders:"
        $open = Get-OpenOrders
        if ($open.Count -eq 0) { Write-Host "  (none)" }
        foreach ($o in $open) { Write-Host "  $($o.side) $($o.qty) $($o.symbol) $($o.type) stop=$($o.stop_price) tif=$($o.time_in_force) status=$($o.status)" }
    }
    $positions = Get-AllPositions
    Write-Host "Positions: $(if ($positions.Count) { ($positions | ForEach-Object { "$($_.qty) $($_.symbol), avg `$$(Fmt $_.avg_entry_price), P/L `$$(Fmt $_.unrealized_pl)" }) -join '; ' } else { '(none)' })"
    exit 0
}

# ---------- Run ----------
$clock = Alpaca GET "/clock"
if (-not $clock.is_open -and -not $DryRun) { Write-Host "Market closed; nothing to do."; exit 0 }

# 1. Scan for an entry (only when there is no open trade).
if ($state.phase -eq "scanning") {
    if ($state.cooldownUntil -and [DateTime]::UtcNow -lt (To-Date $state.cooldownUntil)) { Write-Host "Cooling down after the last trade."; exit 0 }
    if (-not (In-EntryWindow) -and -not $DryRun) { Write-Host "Outside the entry window ($($cfg.entryStartET)-$($cfg.entryEndET) ET)."; exit 0 }
    $held = Get-AllPositions
    if ($held.Count -gt 0) { Write-Host "Account already holds $(($held | ForEach-Object { $_.symbol }) -join ', '); only one trade at a time."; exit 0 }

    $pick = $null
    foreach ($s in $cfg.watchlist) {
        $setup = Find-Setup $s
        Show-Setup $setup
        if ($setup.ok -and -not $pick) { $pick = $setup }
    }
    if (-not $pick) { exit 0 }

    $sym = $pick.symbol
    $acct = Alpaca GET "/account"
    $eq = [double]$acct.equity
    $px = Get-LastPrice $sym
    $qty = [int][math]::Floor($eq * $cfg.entryPctOfEquity / 100 / $px)
    if ($DryRun) { Write-Host "DRY RUN: would buy $qty $sym at market (~`$$(Fmt ($qty * $px))) on $($pick.trigger)."; exit 0 }
    if ($qty -lt 1) { Write-Host "Not enough equity for one share of $sym."; exit 0 }

    $state.symbol           = $sym
    $state.entrySignal      = $pick.trigger
    $state.setupEquity      = $eq
    $state.stopLossUSD      = $eq * $cfg.stopLossPctOfEquity / 100
    $state.ladderLossUSD    = $eq * $cfg.ladderLossPctOfEquity / 100
    $state.trailActivateUSD = $eq * $cfg.trailActivatePctOfEquity / 100
    $o = Alpaca POST "/orders" @{ symbol = $sym; qty = "$qty"; side = "buy"; type = "market"; time_in_force = "day" }
    $state.entryOrderId = $o.id
    $state.phase = "entry_submitted"
    Write-Event "ENTRY_SUBMITTED" $qty $px $null $o.id "$sym $($pick.trigger); equity $(Fmt $eq)"
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
        Write-Event "ENTRY_FILLED" $q $p $state.floor $o.id "$sym ladder at $(Fmt $state.ladderPrice)"
        Write-Event "FLOOR_PLACED" $q $null $state.floor $stop.id "GTC stop sell"
    } elseif ($o.status -in @("canceled", "expired", "rejected")) {
        Write-Event "ENTRY_FAILED" $null $null $null $o.id $o.status
        $state = New-TradeState $state.tradeCount $null
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
        if ($stop -and $stop.status -eq "filled") {
            Write-Event "SOLD" $stop.filled_qty $stop.filled_avg_price $state.floor $stop.id "floor hit"
            $why = "floor hit at $(Fmt $stop.filled_avg_price)"
        } else { $why = "position gone" }
        Cancel-OpenOrders
        Finish-Trade $why
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
