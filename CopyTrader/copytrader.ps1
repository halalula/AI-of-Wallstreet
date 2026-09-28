# CopyTrader -- mirrors a politician's disclosed trades (from capitoltrades.com)
# into an Alpaca PAPER account.
#
# Each run:
#   1. Scrapes the politician's trade list from Capitol Trades (the page embeds
#      the full trade JSON, including the options description text).
#   2. Checks earlier submitted orders (filled / expired -> retry / failed).
#   3. For every new disclosure, copies it:
#        stock buy   -> notional market buy, sized by the disclosure's size bracket
#        stock sell  -> closes our position in that ticker
#        option buy  -> buys the SAME contract (ticker/expiry/strike/call|put) with a
#                       limit order at the ask; if one contract is too big for the
#                       account, buys the underlying stock as a proxy instead
#        option sell -> sells our matching contract (or its stock proxy)
#        exercise    -> sells our matching contract and buys the stock with the proceeds
#   4. Closes any option we hold that is about to expire.
#
# Disclosures lag the real trade by up to 45 days (STOCK Act), so we always
# copy late. This is an automation of rules you configured, not investment
# advice. SAFETY: orders only ever go to the paper endpoint.

param(
    # Scrape and plan, but never submit orders or change state.
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
    Write-Error "Set APCA_API_KEY_ID and APCA_API_SECRET_KEY in CopyTrader\.env first."
    exit 1
}
$headers = @{
    "APCA-API-KEY-ID"     = $env:APCA_API_KEY_ID
    "APCA-API-SECRET-KEY" = $env:APCA_API_SECRET_KEY
}

$cfg = Get-Content (Join-Path $root "copy_config.json") -Raw | ConvertFrom-Json
if ($cfg.mode -ne "paper") { Write-Error "CopyTrader only supports mode=paper."; exit 1 }
$tradingBase = "https://paper-api.alpaca.markets/v2"
$dataBase    = "https://data.alpaca.markets"
$inv = [System.Globalization.CultureInfo]::InvariantCulture

# ---------- Paths ----------
$stateDir = Join-Path $root "state"
$logDir   = Join-Path $root "logs"
New-Item -ItemType Directory -Force -Path $stateDir, $logDir | Out-Null
$statePath = Join-Path $stateDir "processed_trades.json"
$logPath   = Join-Path $logDir "copy_log.csv"
if (-not (Test-Path $logPath)) {
    "timestamp,politician,txId,tradeDate,pubDate,action,symbol,qtyOrNotional,orderId,status,note" |
        Out-File -FilePath $logPath -Encoding utf8
}

$nowUtc = [DateTime]::UtcNow
$etNow  = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($nowUtc, "Eastern Standard Time")

function Write-CopyLog($rec, $action, $symbol, $amount, $orderId, $status, $note) {
    $ts = [DateTime]::UtcNow.ToString("o")
    $note = "$note" -replace '"', "'"
    $line = "$ts,$($rec.politician),$($rec.txId),$($rec.txDate),$($rec.pubDate),$action,$symbol,$amount,$orderId,$status,`"$note`""
    Write-Host $line
    if (-not $DryRun) { Add-Content -Path $logPath -Value $line }
}

function To-Date($s) {
    if ($s -is [DateTime]) { return $s.ToUniversalTime() }
    return [DateTime]::Parse("$s", $inv, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
}

function Alpaca($method, $path, $body) {
    $req = @{ Method = $method; Uri = "$tradingBase$path"; Headers = $headers }
    if ($body) { $req.Body = ($body | ConvertTo-Json); $req.ContentType = "application/json" }
    return Invoke-RestMethod @req
}

# ---------- 1. Scrape Capitol Trades ----------
# Capitol Trades rejects PowerShell's web client (TLS fingerprint), so use curl.exe.
function Get-PoliticianTrades($pol) {
    $url = "https://www.capitoltrades.com/trades?politician=$($pol.id)&pageSize=96"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "ct_$($pol.id).html"
    $ua  = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"
    $code = ""
    for ($i = 1; $i -le 3; $i++) {
        $code = & curl.exe -s --compressed -A $ua -H "Accept: text/html" -H "Accept-Language: en-US,en;q=0.9" -o $tmp -w "%{http_code}" $url
        if ($code -eq "200") { break }
        Write-Host "Capitol Trades returned HTTP $code (attempt $i), retrying..."
        Start-Sleep -Seconds (15 * $i)
    }
    if ($code -ne "200") { throw "Capitol Trades fetch failed for $($pol.name): HTTP $code" }
    $html = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)

    # The trade data lives in Next.js flight chunks: self.__next_f.push([1,"<escaped json>"])
    $sb = New-Object Text.StringBuilder
    foreach ($m in [regex]::Matches($html, 'self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)')) {
        [void]$sb.Append([regex]::Unescape($m.Groups[1].Value))
    }
    $flight = $sb.ToString()

    $trades = @{}
    $pos = 0
    while (($start = $flight.IndexOf('{"_issuerId":', $pos)) -ge 0) {
        # Walk to the matching closing brace, skipping braces inside strings.
        $depth = 0; $inStr = $false; $end = -1
        for ($j = $start; $j -lt $flight.Length; $j++) {
            $c = $flight[$j]
            if ($inStr) {
                if ($c -eq '\') { $j++ } elseif ($c -eq '"') { $inStr = $false }
            } elseif ($c -eq '"') { $inStr = $true }
            elseif ($c -eq '{') { $depth++ }
            elseif ($c -eq '}') { $depth--; if ($depth -eq 0) { $end = $j; break } }
        }
        if ($end -lt 0) { break }
        $pos = $end + 1
        try { $t = $flight.Substring($start, $end - $start + 1) | ConvertFrom-Json } catch { continue }
        if (-not $t._txId -or $t._politicianId -ne $pol.id) { continue }
        $trades["$($t._txId)"] = $t
    }
    return $trades.Values
}

# ---------- Trade classification ----------
function Parse-Trade($t, $polName) {
    $ticker = $null
    if ($t.issuer -and $t.issuer.issuerTicker) { $ticker = ($t.issuer.issuerTicker -split ':')[0].ToUpper() }
    $comment = "$($t.comment)"
    $rec = [ordered]@{
        txId = "$($t._txId)"; politician = $polName; txDate = "$($t.txDate)"
        pubDate = (To-Date $t.pubDate).ToString("yyyy-MM-ddTHH:mm:ssZ")
        txType = "$($t.txType)"; value = [double]($(if ($t.value) { $t.value } else { 0 }))
        ticker = $ticker; comment = $comment; kind = "skip"; side = $null
        optionSymbol = $null; optType = $null; strike = $null; expiry = $null; contracts = $null
        status = "new"; attempts = 0; orderId = $null; orderKind = $null
        proxyForOption = $null; filledQty = $null; note = ""
    }

    if (-not $ticker) { $rec.note = "no tradable ticker"; return $rec }
    if ($comment -match '(?i)contribution|gift|donat') { $rec.note = "donation/transfer, not a trade"; return $rec }

    if ($comment -match '(?i)exercised\s+([\d,]+)\s+(call|put)\s+options?.*?strike price of \$([\d,\.]+)') {
        $rec.kind = "exercise"; $rec.optType = $Matches[2].Substring(0,1).ToUpper()
        $rec.strike = [double]($Matches[3] -replace ',', ''); return $rec
    }

    if ($comment -match '(?i)(purchased|bought|sold|sale of)\s+([\d,]+)\s+(call|put)\s+options?\s+with a strike price of \$([\d,\.]+)\s+and an expiration date of\s+(\d{1,2})/(\d{1,2})/(\d{2,4})') {
        $verb = $Matches[1].ToLower()
        $rec.side = if ($verb -in "purchased", "bought") { "buy" } else { "sell" }
        $rec.contracts = [int]($Matches[2] -replace ',', '')
        $rec.optType = $Matches[3].Substring(0,1).ToUpper()
        $rec.strike = [double]($Matches[4] -replace ',', '')
        $yr = [int]$Matches[7]; if ($yr -lt 100) { $yr += 2000 }
        $exp = New-Object DateTime $yr, ([int]$Matches[5]), ([int]$Matches[6])
        $rec.expiry = $exp.ToString("yyyy-MM-dd")
        $rec.optionSymbol = "{0}{1}{2}{3:D8}" -f $ticker, $exp.ToString("yyMMdd"), $rec.optType, [long][Math]::Round($rec.strike * 1000)
        $rec.kind = "option"; return $rec
    }

    if ($rec.txType -in "buy", "sell") { $rec.kind = "stock"; $rec.side = $rec.txType; return $rec }
    $rec.note = "unsupported transaction type '$($rec.txType)'"
    return $rec
}

# ---------- State ----------
$state = [ordered]@{}
$firstRun = -not (Test-Path $statePath)
if (-not $firstRun) {
    foreach ($r in (Get-Content $statePath -Raw | ConvertFrom-Json)) {
        $h = [ordered]@{}; foreach ($p in $r.PSObject.Properties) { $h[$p.Name] = $p.Value }
        $state[$h.txId] = $h
    }
}
function Save-State {
    if ($DryRun) { return }
    $arr = @($state.Values | Sort-Object { $_.pubDate })
    ConvertTo-Json -InputObject $arr -Depth 5 | Out-File -FilePath $statePath -Encoding utf8
}

$newCount = 0
foreach ($pol in $cfg.politicians) {
    $raw = Get-PoliticianTrades $pol
    Write-Host "$($pol.name): $(@($raw).Count) disclosed trades on Capitol Trades"
    foreach ($t in $raw) {
        if ($state.Contains("$($t._txId)")) { continue }
        $rec = Parse-Trade $t $pol.name
        $age = ($nowUtc - (To-Date $rec.pubDate)).TotalDays
        $limitDays = if ($firstRun) { $cfg.firstRunBackfillDays } else { $cfg.maxDisclosureAgeDays }
        if ($rec.kind -eq "skip") { $rec.status = "skipped" }
        elseif ($age -gt $limitDays) { $rec.status = "skipped"; $rec.note = "published $([int]$age) days ago (older than $limitDays-day window)" }
        else { $newCount++ }
        $state[$rec.txId] = $rec
        if ($rec.status -eq "skipped" -and -not $firstRun) { Write-CopyLog $rec "skip" $rec.ticker "" "" "skipped" $rec.note }
    }
}
Write-Host "New disclosures to copy: $newCount"
Save-State

# ---------- Market / account ----------
$clock = Alpaca GET "/clock"
if (-not $clock.is_open -and -not $DryRun) {
    Write-Host "Market closed -- new disclosures are queued for the next market-hours run."
    exit 0
}
$acct = Alpaca GET "/account"
$equity = [double]$acct.equity
$cash   = [double]$acct.cash
$positions = @(Alpaca GET "/positions" | ForEach-Object { $_ } | Where-Object { $_.symbol })
Write-Host ("Equity {0:N2} | cash {1:N2} | positions {2}" -f $equity, $cash, $positions.Count)

function Get-Position($sym) { return $positions | Where-Object { $_.symbol -eq $sym } | Select-Object -First 1 }
function Symbol-Exposure($ticker) {
    $sum = 0.0
    foreach ($p in $positions) {
        if ($p.symbol -eq $ticker -or ($p.asset_class -eq "us_option" -and $p.symbol -match "^$ticker\d{6}[CP]")) { $sum += [double]$p.market_value }
    }
    return $sum
}
function Budget-For($rec) {
    $pct = ($cfg.sizeTiers | Where-Object { $rec.value -le $_.maxValue } | Select-Object -First 1).pctOfEquity
    if (-not $pct) { $pct = 2 }
    $b = $equity * $pct / 100
    $room = $equity * $cfg.maxSymbolPctOfEquity / 100 - (Symbol-Exposure $rec.ticker)
    $spendable = $cash - $equity * $cfg.cashReservePct / 100
    return [Math]::Floor([Math]::Min($b, [Math]::Min($room, $spendable)) * 100) / 100
}
function Option-Quote($occ) {
    $q = Invoke-RestMethod -Uri "$dataBase/v1beta1/options/quotes/latest?symbols=$occ&feed=indicative" -Headers $headers
    return $q.quotes.$occ
}
function Round-Tick($price, [switch]$Up) {
    $tick = if ($price -ge 3) { 0.05 } else { 0.01 }
    $n = $price / $tick
    $n = if ($Up) { [Math]::Ceiling($n - 1e-9) } else { [Math]::Floor($n + 1e-9) }
    return [Math]::Round([Math]::Max($n * $tick, $tick), 2)
}
function Fmt($x) { return ([double]$x).ToString("0.##", $inv) }

function Submit($rec, $body, $kind, $note) {
    if ($DryRun) { Write-CopyLog $rec "DRYRUN-$($body.side)" $body.symbol "$($body.qty)$($body.notional)" "" "planned" $note; return }
    try {
        $o = Alpaca POST "/orders" $body
        $rec.status = "submitted"; $rec.orderId = $o.id; $rec.orderKind = $kind; $rec.attempts++
        $rec.note = $note
        Write-CopyLog $rec $body.side $body.symbol "$($body.qty)$($body.notional)" $o.id $o.status $note
    } catch {
        $rec.attempts++
        $msg = $_.ErrorDetails.Message; if (-not $msg) { $msg = $_.Exception.Message }
        $rec.note = "order rejected: $msg"
        if ($rec.attempts -ge $cfg.maxOrderAttempts) { $rec.status = "failed" }
        Write-CopyLog $rec $body.side $body.symbol "$($body.qty)$($body.notional)" "" "rejected" $msg
    }
}

function Buy-StockNotional($rec, $ticker, $usd, $kind, $note) {
    if ($usd -lt $cfg.minOrderUSD) { $rec.status = "skipped"; $rec.note = "budget $(Fmt $usd) below minimum (cash or per-symbol cap)"; Write-CopyLog $rec "skip" $ticker "" "" "skipped" $rec.note; return }
    Submit $rec @{ symbol = $ticker; notional = (Fmt $usd); side = "buy"; type = "market"; time_in_force = "day" } $kind $note
}

function Sell-StockQty($rec, $ticker, $qty, $note) {
    $pos = Get-Position $ticker
    if (-not $pos -or $pos.asset_class -ne "us_equity") { $rec.status = "skipped"; $rec.note = "we hold no $ticker stock"; Write-CopyLog $rec "skip" $ticker "" "" "skipped" $rec.note; return }
    $held = [double]$pos.qty
    if (-not $qty -or $qty -ge $held - 1e-6) { $qty = $held }
    Submit $rec @{ symbol = $ticker; qty = (([Math]::Floor($qty * 1e6)) / 1e6).ToString("0.######", $inv); side = "sell"; type = "market"; time_in_force = "day" } "stock" $note
}

# ---------- 2. Reconcile submitted orders ----------
foreach ($rec in @($state.Values | Where-Object { $_.status -eq "submitted" })) {
    try { $o = Alpaca GET "/orders/$($rec.orderId)" } catch { continue }
    switch ($o.status) {
        "filled" { $rec.status = "filled"; $rec.filledQty = $o.filled_qty; Write-CopyLog $rec "fill" $o.symbol $o.filled_qty $o.id "filled" "avg price $($o.filled_avg_price)" }
        { $_ -in "canceled", "expired", "rejected" } {
            if ([double]$o.filled_qty -gt 0) {
                $rec.status = "filled"; $rec.filledQty = $o.filled_qty
                Write-CopyLog $rec "fill" $o.symbol $o.filled_qty $o.id "partial" "partially filled before $($o.status)"
            } elseif ($rec.attempts -ge $cfg.maxOrderAttempts) {
                $rec.status = "failed"; Write-CopyLog $rec "fail" $o.symbol "" $o.id $o.status "gave up after $($rec.attempts) attempts"
            } else { $rec.status = "new"; $rec.orderId = $null }
        }
    }
}
Save-State

# ---------- 3. Copy new disclosures (oldest first) ----------
$todo = @($state.Values | Where-Object { $_.status -eq "new" } | Sort-Object { $_.txDate }, { $_.txId })
foreach ($rec in $todo) {
    $ticker = $rec.ticker
    switch ($rec.kind) {
        "stock" {
            if ($rec.side -eq "buy") {
                Buy-StockNotional $rec $ticker (Budget-For $rec) "stock" "copy stock buy ($($rec.comment))"
            } else {
                Sell-StockQty $rec $ticker $null "copy stock sale ($($rec.comment))"
            }
        }
        "option" {
            $occ = $rec.optionSymbol
            if ($rec.side -eq "buy") {
                $daysLeft = ([DateTime]::Parse($rec.expiry, $inv) - $etNow.Date).TotalDays
                if ($daysLeft -lt $cfg.minDaysToExpiryToOpen) {
                    $rec.status = "skipped"; $rec.note = "contract expires in $([int]$daysLeft) days"; Write-CopyLog $rec "skip" $occ "" "" "skipped" $rec.note; continue
                }
                $contract = $null
                try { $contract = Alpaca GET "/options/contracts/$occ" } catch { }
                $budget = Budget-For $rec
                if (-not $contract -or -not $contract.tradable) {
                    $note = "contract $occ not tradable on Alpaca"
                    if ($cfg.optionStockProxyFallback) { $rec.proxyForOption = $occ; Buy-StockNotional $rec $ticker $budget "proxy" "$note; bought stock proxy" }
                    else { $rec.status = "skipped"; $rec.note = $note; Write-CopyLog $rec "skip" $occ "" "" "skipped" $note }
                    continue
                }
                $q = Option-Quote $occ
                $ask = if ($q -and [double]$q.ap -gt 0) { [double]$q.ap } else { [double]$contract.close_price }
                $limit = Round-Tick $ask -Up
                $perContract = $limit * 100
                $n = [Math]::Floor($budget / $perContract)
                $maxOne = $equity * $cfg.optionSingleContractMaxPctOfEquity / 100
                if ($n -lt 1 -and $perContract -le $maxOne -and $perContract -le [double]$acct.options_buying_power) { $n = 1 }
                if ($n -ge 1) {
                    Submit $rec @{ symbol = $occ; qty = "$n"; side = "buy"; type = "limit"; limit_price = (Fmt $limit); time_in_force = "day" } "option" "copy option buy: $n x $occ @ $(Fmt $limit) ($($rec.comment))"
                } elseif ($cfg.optionStockProxyFallback) {
                    $rec.proxyForOption = $occ
                    Buy-StockNotional $rec $ticker $budget "proxy" "1 contract of $occ costs `$$(Fmt $perContract) (> budget `$$(Fmt $budget)); bought $ticker stock as proxy"
                } else {
                    $rec.status = "skipped"; $rec.note = "1 contract costs `$$(Fmt $perContract), over budget"; Write-CopyLog $rec "skip" $occ "" "" "skipped" $rec.note
                }
            } else {
                $pos = Get-Position $occ
                if ($pos) {
                    $q = Option-Quote $occ
                    $bid = if ($q -and [double]$q.bp -gt 0) { [double]$q.bp } else { [double]$pos.current_price }
                    Submit $rec @{ symbol = $occ; qty = "$([int][double]$pos.qty)"; side = "sell"; type = "limit"; limit_price = (Fmt (Round-Tick $bid)); time_in_force = "day" } "option" "copy option sale ($($rec.comment))"
                } else {
                    $proxyQty = 0.0
                    foreach ($p in $state.Values) { if ($p.proxyForOption -eq $occ -and $p.status -eq "filled" -and $p.filledQty) { $proxyQty += [double]$p.filledQty } }
                    if ($proxyQty -gt 0) { Sell-StockQty $rec $ticker $proxyQty "copy option sale via stock proxy for $occ" }
                    else { $rec.status = "skipped"; $rec.note = "we hold no $occ (or proxy)"; Write-CopyLog $rec "skip" $occ "" "" "skipped" $rec.note }
                }
            }
        }
        "exercise" {
            $pattern = "^$ticker\d{6}$($rec.optType)(\d{8})$"
            $match = $positions | Where-Object { $_.asset_class -eq "us_option" -and $_.symbol -match $pattern -and ([double]$Matches[1] / 1000) -eq $rec.strike } | Select-Object -First 1
            if (-not $match) {
                $rec.status = "skipped"; $rec.note = "exercise: no matching $ticker $($rec.strike) $($rec.optType) held (stock proxy already equivalent)"
                Write-CopyLog $rec "skip" $ticker "" "" "skipped" $rec.note; continue
            }
            # Mirror the exercise as: sell the contract, then buy the stock with the proceeds.
            $q = Option-Quote $match.symbol
            $bid = if ($q -and [double]$q.bp -gt 0) { [double]$q.bp } else { [double]$match.current_price }
            $proceeds = $bid * 100 * [int][double]$match.qty
            Submit $rec @{ symbol = $match.symbol; qty = "$([int][double]$match.qty)"; side = "sell"; type = "limit"; limit_price = (Fmt (Round-Tick $bid)); time_in_force = "day" } "option" "exercise mirror: sell contract"
            if ($rec.status -eq "submitted" -and -not $DryRun) {
                try {
                    $o = Alpaca POST "/orders" @{ symbol = $ticker; notional = (Fmt ([Math]::Floor($proceeds * 0.98))); side = "buy"; type = "market"; time_in_force = "day" }
                    Write-CopyLog $rec "buy" $ticker (Fmt ($proceeds * 0.98)) $o.id $o.status "exercise mirror: buy stock with contract proceeds"
                } catch { Write-CopyLog $rec "buy" $ticker "" "" "rejected" "exercise mirror stock buy failed: $($_.Exception.Message)" }
            }
        }
    }
    Save-State
    # Refresh balances so later trades in this run size off the new cash.
    if (-not $DryRun) {
        $acct = Alpaca GET "/account"; $cash = [double]$acct.cash; $equity = [double]$acct.equity
        $positions = @(Alpaca GET "/positions" | ForEach-Object { $_ } | Where-Object { $_.symbol })
    }
}

# ---------- 4. Close options that are about to expire ----------
foreach ($p in @($positions | Where-Object { $_.asset_class -eq "us_option" })) {
    if ($p.symbol -notmatch '\d{6}(?=[CP]\d{8}$)') { continue }
    $exp = [DateTime]::ParseExact($Matches[0], "yyMMdd", $inv)
    if (($exp - $etNow.Date).TotalDays -le $cfg.closeOptionsDaysBeforeExpiry) {
        $rec = @{ politician = "-"; txId = "expiry-guard"; txDate = ""; pubDate = ""; attempts = 0 }
        $q = Option-Quote $p.symbol
        $bid = if ($q -and [double]$q.bp -gt 0) { [double]$q.bp } else { [double]$p.current_price }
        Submit $rec @{ symbol = $p.symbol; qty = "$([int][double]$p.qty)"; side = "sell"; type = "limit"; limit_price = (Fmt (Round-Tick $bid)); time_in_force = "day" } "option" "closing before expiry $($exp.ToString('yyyy-MM-dd'))"
    }
}

Save-State
Write-Host "CopyTrader run complete."
