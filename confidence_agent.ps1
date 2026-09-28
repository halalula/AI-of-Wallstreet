# Mason -- confidence-score trading agent for Alpaca.
#
# Combines technical signals (MA crossover, RSI, volume) with a keyword-based
# news/political sentiment score into a single 0-100 confidence rating per
# symbol, then buys/sells according to strategy_config.json thresholds.
#
# Mason is tuned to be an aggressive trader: buy/sell thresholds are looser
# than a conservative setup, and a "forced trade" fallback tops up the day's
# activity to at least minTradesPerDay if natural signals don't get there on
# their own -- but only using candidates at/above forcedTradeMinConfidence,
# and never past maxTradesPerDay or through a tripped circuit breaker.
#
# SAFETY: this script only ever auto-submits orders when mode == "paper".
# If strategy_config.json has mode == "live", proposed trades are written to
# pending_live_orders.json and logged, but NOT submitted. Submitting a live
# order always requires a separate, explicit, human-confirmed action.
#
# This is an automation tool executing rules YOU configured. It is not
# investment advice, and past/backtested behavior of these rules is no
# guarantee of future results.

param(
    # Runs the full analysis pipeline even when the market is closed, and
    # never submits an order (paper or live) -- just logs what it WOULD do.
    # Use this to sanity-check the strategy without waiting for market hours.
    [switch]$DryRun
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
    Write-Error "Set APCA_API_KEY_ID and APCA_API_SECRET_KEY in .env first."
    exit 1
}
$headers = @{
    "APCA-API-KEY-ID"     = $env:APCA_API_KEY_ID
    "APCA-API-SECRET-KEY" = $env:APCA_API_SECRET_KEY
}

# ---------- Load config ----------
$configPath = Join-Path $root "strategy_config.json"
$cfg = Get-Content $configPath -Raw | ConvertFrom-Json

$tradingBase = if ($cfg.mode -eq "live") { "https://api.alpaca.markets/v2" } else { "https://paper-api.alpaca.markets/v2" }
$dataBase    = "https://data.alpaca.markets"

# ---------- State / logging paths ----------
$stateDir = Join-Path $root "state"
$logDir   = Join-Path $root "logs"
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$dailyStatePath      = Join-Path $stateDir "daily_state.json"
$pendingLiveOrders   = Join-Path $root "pending_live_orders.json"
$tradeLogPath        = Join-Path $logDir "trade_log.csv"

if (-not (Test-Path $tradeLogPath)) {
    "timestamp,mode,symbol,technicalScore,sentimentScore,politicalFlag,confidence,decision,qty,orderId,note" |
        Out-File -FilePath $tradeLogPath -Encoding utf8
}

function Write-TradeLog {
    param($symbol, $technicalScore, $sentimentScore, $politicalFlag, $confidence, $decision, $qty, $orderId, $note)
    $ts = (Get-Date).ToUniversalTime().ToString("o")
    $line = "$ts,$($cfg.mode),$symbol,$technicalScore,$sentimentScore,$politicalFlag,$confidence,$decision,$qty,$orderId,`"$note`""
    Add-Content -Path $tradeLogPath -Value $line
}

# ---------- Market clock check ----------
$clock = Invoke-RestMethod -Uri "$tradingBase/clock" -Headers $headers
if (-not $clock.is_open -and -not $DryRun) {
    Write-Host "Market is closed (next open: $($clock.next_open)). Skipping this run."
    exit 0
}
if (-not $clock.is_open -and $DryRun) {
    Write-Host "(DryRun) Market is closed, but continuing analysis anyway. No orders will be submitted."
}

# ---------- Account / daily circuit breaker state ----------
$acct = Invoke-RestMethod -Uri "$tradingBase/account" -Headers $headers
$equity = [double]$acct.equity
# Trading day is always the Eastern Time date, even on UTC machines (e.g. GitHub Actions).
$today = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, "Eastern Standard Time").ToString("yyyy-MM-dd")

$dailyState = $null
if (Test-Path $dailyStatePath) {
    $dailyState = Get-Content $dailyStatePath -Raw | ConvertFrom-Json
}
if (-not $dailyState -or $dailyState.date -ne $today) {
    $dailyState = [PSCustomObject]@{
        date         = $today
        startEquity  = $equity
        tradedSymbols = @()
        tradeCount   = 0
    }
}
if (-not (Get-Member -InputObject $dailyState -Name "tradeCount")) {
    $dailyState | Add-Member -NotePropertyName "tradeCount" -NotePropertyValue 0
}

$dailyLossPct = (($dailyState.startEquity - $equity) / $dailyState.startEquity) * 100
$circuitBreakerTripped = $dailyLossPct -ge $cfg.maxDailyLossPct
if ($circuitBreakerTripped) {
    Write-Host "Circuit breaker TRIPPED: daily loss $([math]::Round($dailyLossPct,2))% >= max $($cfg.maxDailyLossPct)%. New buys blocked; sells still allowed."
}

# ---------- Current positions ----------
$positionsRaw = Invoke-RestMethod -Uri "$tradingBase/positions" -Headers $headers
$positions = @{}
foreach ($p in $positionsRaw) { $positions[$p.symbol] = [double]$p.qty }

# ---------- Technical scoring ----------
function Get-RSI {
    param([double[]]$closes, [int]$period)
    if ($closes.Count -lt ($period + 1)) { return 50 }
    $gains = @(); $losses = @()
    for ($i = 1; $i -lt $closes.Count; $i++) {
        $diff = $closes[$i] - $closes[$i - 1]
        if ($diff -ge 0) { $gains += $diff; $losses += 0 } else { $gains += 0; $losses += [math]::Abs($diff) }
    }
    $recentGains = $gains[-$period..-1]
    $recentLosses = $losses[-$period..-1]
    $avgGain = ($recentGains | Measure-Object -Average).Average
    $avgLoss = ($recentLosses | Measure-Object -Average).Average
    if ($avgLoss -eq 0) { return 100 }
    $rs = $avgGain / $avgLoss
    return 100 - (100 / (1 + $rs))
}

function Get-TechnicalScore {
    param($symbol)
    $limit = $cfg.longMaPeriod + $cfg.rsiPeriod + 10
    # This data plan requires an explicit start/end window; limit alone returns nothing.
    $calendarDaysBack = [math]::Ceiling($limit * 1.6) + 10  # pad for weekends/holidays
    $start = (Get-Date).AddDays(-$calendarDaysBack).ToString("yyyy-MM-dd")
    $end = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")
    $uri = "$dataBase/v2/stocks/$symbol/bars?timeframe=1Day&start=$start&end=$end&limit=$limit&feed=iex"
    $resp = Invoke-RestMethod -Uri $uri -Headers $headers
    $bars = $resp.bars
    if (-not $bars -or $bars.Count -lt ($cfg.longMaPeriod + 1)) {
        return @{ score = 50; lastClose = $null; note = "insufficient bar history" }
    }
    $closes = $bars | ForEach-Object { [double]$_.c }
    $volumes = $bars | ForEach-Object { [double]$_.v }

    $shortMA = ($closes[-$cfg.shortMaPeriod..-1] | Measure-Object -Average).Average
    $longMA  = ($closes[-$cfg.longMaPeriod..-1]  | Measure-Object -Average).Average
    $rsi = Get-RSI -closes $closes -period $cfg.rsiPeriod
    $avgVol = ($volumes[-$cfg.longMaPeriod..-1] | Measure-Object -Average).Average
    $lastVol = $volumes[-1]
    $lastClose = $closes[-1]
    $priceChangeUp = $closes[-1] -gt $closes[-2]

    # Base score from MA crossover direction, scaled by separation
    $sep = ($shortMA - $longMA) / $longMA
    $trendScore = 50 + ([math]::Max([math]::Min($sep * 500, 30), -30))

    # RSI tilt: oversold => bullish tilt, overbought => bearish tilt
    $rsiTilt = 0
    if ($rsi -lt 30) { $rsiTilt = 15 }
    elseif ($rsi -gt 70) { $rsiTilt = -15 }

    # Volume confirmation: above-average volume reinforces the direction of last move
    $volTilt = 0
    if ($lastVol -gt ($avgVol * 1.2)) {
        $volTilt = if ($priceChangeUp) { 8 } else { -8 }
    }

    $score = $trendScore + $rsiTilt + $volTilt
    $score = [math]::Max(0, [math]::Min(100, $score))

    return @{
        score = [math]::Round($score, 1)
        lastClose = $lastClose
        note = "shortMA=$([math]::Round($shortMA,2)) longMA=$([math]::Round($longMA,2)) rsi=$([math]::Round($rsi,1))"
    }
}

# ---------- News / political sentiment scoring ----------
$positiveWords = @("upgrade","beat","surge","approval","approved","deal","partnership","growth","record profit",
                    "expansion","tax cut","stimulus","rate cut","outperform","raises guidance","buyback")
$negativeWords = @("downgrade","miss","lawsuit","investigation","tariff","sanction","recall","antitrust",
                    "regulation","rate hike","ban","strike","fraud","recession","default","probe","layoffs")
$politicalWords = @("election","congress","senate","white house","regulation","tariff","sanction","policy",
                     "fed ","federal reserve","antitrust","supreme court","executive order","trade war")

function Get-SentimentScore {
    param($symbol)
    $start = (Get-Date).AddDays(-$cfg.newsLookbackDays).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $uri = "$dataBase/v1beta1/news?symbols=$symbol&limit=$($cfg.newsLimitPerSymbol)&start=$start"
    try {
        $resp = Invoke-RestMethod -Uri $uri -Headers $headers
    } catch {
        return @{ score = 50; political = $false; politicalNegative = $false; note = "news fetch failed" }
    }
    $articles = $resp.news
    if (-not $articles -or $articles.Count -eq 0) {
        return @{ score = 50; political = $false; politicalNegative = $false; note = "no recent news" }
    }

    $sentiments = @()
    $anyPolitical = $false
    $politicalNegativeCount = 0

    foreach ($a in $articles) {
        $text = "$($a.headline) $($a.summary)".ToLower()
        $pos = 0; $neg = 0
        foreach ($w in $positiveWords) { if ($text -like "*$w*") { $pos++ } }
        foreach ($w in $negativeWords) { if ($text -like "*$w*") { $neg++ } }
        $isPolitical = $false
        foreach ($w in $politicalWords) { if ($text -like "*$w*") { $isPolitical = $true; break } }
        if ($isPolitical) {
            $anyPolitical = $true
            if ($neg -gt $pos) { $politicalNegativeCount++ }
        }
        $s = ($pos - $neg) / ($pos + $neg + 1)
        $sentiments += $s
    }

    $avgSentiment = ($sentiments | Measure-Object -Average).Average
    $score = 50 + ($avgSentiment * 50)
    $score = [math]::Max(0, [math]::Min(100, $score))

    return @{
        score = [math]::Round($score, 1)
        political = $anyPolitical
        politicalNegative = ($politicalNegativeCount -gt 0)
        note = "$($articles.Count) articles"
    }
}

# ---------- Position sizing ----------
function Get-OrderQty {
    param($lastClose)
    $capByPct = $equity * ($cfg.maxPositionPctOfEquity / 100)
    $capUSD = [math]::Min($capByPct, $cfg.maxPositionCapUSD)
    $qty = [math]::Floor($capUSD / $lastClose)
    return [int]$qty
}

$agentName = if ($cfg.agentName) { $cfg.agentName } else { "Agent" }

# ---------- Pass 1: evaluate every symbol ----------
$evaluations = @()
foreach ($symbol in $cfg.watchlist) {
    Write-Host "`n--- $symbol ---"
    $tech = Get-TechnicalScore -symbol $symbol
    $sent = Get-SentimentScore -symbol $symbol

    $confidence = ($tech.score * $cfg.technicalWeight) + ($sent.score * $cfg.sentimentWeight)
    if ($sent.politicalNegative) {
        $confidence = $confidence * $cfg.negativePoliticalDiscount
    }
    $confidence = [math]::Round($confidence, 1)

    $currentQty = if ($positions.ContainsKey($symbol)) { $positions[$symbol] } else { 0 }
    $alreadyTradedToday = $dailyState.tradedSymbols -contains $symbol

    Write-Host "technical=$($tech.score) ($($tech.note))  sentiment=$($sent.score) (political=$($sent.political), negPolitical=$($sent.politicalNegative), $($sent.note))  => confidence=$confidence  currentQty=$currentQty"

    $decision = "hold"; $qty = 0; $note = ""; $forced = $false
    $dailyBuyCapReached = $dailyState.tradeCount -ge $cfg.maxTradesPerDay

    if ($currentQty -gt 0 -and $confidence -le $cfg.sellConfidenceThreshold) {
        $decision = "sell"
        $qty = $currentQty
    }
    elseif ($currentQty -eq 0 -and -not $alreadyTradedToday -and -not $circuitBreakerTripped -and -not $dailyBuyCapReached -and $confidence -ge $cfg.buyConfidenceThreshold) {
        if ($tech.lastClose) {
            $decision = "buy"
            $qty = Get-OrderQty -lastClose $tech.lastClose
            if ($qty -lt 1) { $decision = "hold"; $note = "size rounds to 0 shares" }
        } else {
            $decision = "hold"; $note = "no price data"
        }
    }
    elseif ($circuitBreakerTripped -and $confidence -ge $cfg.buyConfidenceThreshold -and $currentQty -eq 0) {
        $note = "buy signal suppressed by circuit breaker"
    }
    elseif ($dailyBuyCapReached -and $confidence -ge $cfg.buyConfidenceThreshold -and $currentQty -eq 0) {
        $note = "buy signal suppressed: maxTradesPerDay ($($cfg.maxTradesPerDay)) already reached"
    }

    $evaluations += [PSCustomObject]@{
        symbol = $symbol; tech = $tech; sent = $sent; confidence = $confidence
        currentQty = $currentQty; decision = $decision; qty = $qty; note = $note; forced = $forced
    }
}

# ---------- Pass 2: force trades if today is still below the aggressive minimum ----------
# Mason is configured to trade at least $minTradesPerDay times/day. Natural signals
# above buyConfidenceThreshold usually cover this, but on quiet days we top up with
# the best remaining candidates -- never below forcedTradeMinConfidence, and never
# bypassing the circuit breaker or the max-trades-per-day ceiling.
$plannedTradesThisRun = ($evaluations | Where-Object { $_.decision -in @("buy","sell") }).Count
$projectedTotal = $dailyState.tradeCount + $plannedTradesThisRun

if (-not $circuitBreakerTripped -and $projectedTotal -lt $cfg.minTradesPerDay) {
    $candidates = $evaluations | Where-Object {
        $_.decision -eq "hold" -and $_.currentQty -eq 0 -and $_.tech.lastClose -and
        $_.confidence -ge $cfg.forcedTradeMinConfidence -and
        -not ($dailyState.tradedSymbols -contains $_.symbol)
    } | Sort-Object -Property confidence -Descending

    foreach ($c in $candidates) {
        if (($dailyState.tradeCount + $plannedTradesThisRun) -ge $cfg.maxTradesPerDay) { break }
        if ($projectedTotal -ge $cfg.minTradesPerDay) { break }
        $qty = Get-OrderQty -lastClose $c.tech.lastClose
        if ($qty -lt 1) { continue }
        $c.decision = "buy"; $c.qty = $qty; $c.forced = $true
        $c.note = "forced buy: Mason's daily minimum ($($cfg.minTradesPerDay) trades) not yet met (confidence $($c.confidence) >= floor $($cfg.forcedTradeMinConfidence))"
        $plannedTradesThisRun++
        $projectedTotal++
    }
}

# ---------- Pass 3: execute decisions ----------
foreach ($e in $evaluations) {
    $symbol = $e.symbol; $tech = $e.tech; $sent = $e.sent; $confidence = $e.confidence
    $decision = $e.decision; $qty = $e.qty; $note = $e.note
    $orderId = ""

    if ($decision -eq "buy" -or $decision -eq "sell") {
        $side = $decision
        if ($DryRun) {
            $note = "DRY RUN: would $side $qty $symbol (not submitted)" + $(if ($e.forced) { " [forced]" } else { "" })
            Write-Host "-> (DryRun) would $side $qty $symbol. Confidence=$confidence$(if ($e.forced) { ' [forced]' })"
        }
        elseif ($cfg.mode -eq "paper") {
            try {
                $body = @{
                    symbol        = $symbol
                    qty           = "$qty"
                    side          = $side
                    type          = "market"
                    time_in_force = "day"
                } | ConvertTo-Json
                $order = Invoke-RestMethod -Method Post -Uri "$tradingBase/orders" -Headers $headers -Body $body -ContentType "application/json"
                $orderId = $order.id
                $note = "submitted (paper)" + $(if ($e.forced) { " [forced trade]" } else { "" })
                Write-Host "-> $side $qty $symbol submitted. Order id: $orderId$(if ($e.forced) { ' [forced]' })"
                $dailyState.tradedSymbols += $symbol
                $dailyState.tradeCount++
            } catch {
                # Never let one rejected/failed order crash the whole run -- log it and move on.
                $errMsg = $_.Exception.Message
                try {
                    $stream = $_.Exception.Response.GetResponseStream()
                    if ($stream) {
                        $reader = New-Object System.IO.StreamReader($stream)
                        $body = $reader.ReadToEnd()
                        if ($body) { $errMsg = "$errMsg | $body" }
                    }
                } catch {}
                $note = "SUBMIT FAILED: $errMsg"
                Write-Host "-> $side $qty $symbol FAILED to submit: $errMsg"
            }
        } else {
            # LIVE mode: never auto-submit. Record as a pending proposal for human review.
            $pending = @()
            if (Test-Path $pendingLiveOrders) {
                $pending = @(Get-Content $pendingLiveOrders -Raw | ConvertFrom-Json)
            }
            $pending += [PSCustomObject]@{
                timestamp  = (Get-Date).ToUniversalTime().ToString("o")
                symbol     = $symbol
                side       = $side
                qty        = $qty
                confidence = $confidence
                forced     = $e.forced
                status     = "PENDING_HUMAN_CONFIRMATION"
            }
            $pending | ConvertTo-Json -Depth 5 | Out-File -FilePath $pendingLiveOrders -Encoding utf8
            $note = "LIVE mode: proposal written to pending_live_orders.json, NOT submitted"
            Write-Host "-> $side $qty $symbol proposed but NOT submitted (live mode requires manual confirmation). See pending_live_orders.json"
        }
    }

    Write-TradeLog -symbol $symbol -technicalScore $tech.score -sentimentScore $sent.score `
        -politicalFlag $sent.political -confidence $confidence -decision $decision -qty $qty -orderId $orderId -note $note
}

$dailyState | ConvertTo-Json -Depth 5 | Out-File -FilePath $dailyStatePath -Encoding utf8
Write-Host "`n$agentName is done for this run. Trades today so far: $($dailyState.tradeCount) (min target: $($cfg.minTradesPerDay)). Log: $tradeLogPath"
