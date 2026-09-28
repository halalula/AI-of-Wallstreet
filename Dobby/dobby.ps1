# Dobby -- mirrors politicians' disclosed trades (official House Clerk filings)
# into an Alpaca PAPER account.
#
# Each run:
#   1. Downloads the House Clerk's filing index, and reads any new Periodic
#      Transaction Report PDFs for the politicians in dobby_config.json.
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
    [switch]$DryRun,
    # Alternate config (for testing); defaults to dobby_config.json.
    [string]$ConfigPath
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
    Write-Error "Set APCA_API_KEY_ID and APCA_API_SECRET_KEY in Dobby/.env first."
    exit 1
}
$headers = @{
    "APCA-API-KEY-ID"     = $env:APCA_API_KEY_ID
    "APCA-API-SECRET-KEY" = $env:APCA_API_SECRET_KEY
}

if (-not $ConfigPath) { $ConfigPath = Join-Path $root "dobby_config.json" }
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if ($cfg.mode -ne "paper") { Write-Error "Dobby only supports mode=paper."; exit 1 }
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

# ---------- 1. Read filings from the House Clerk ----------
# The Clerk publishes a daily index of every disclosure (updated ~9 AM ET) and
# each Periodic Transaction Report (PTR) as a PDF. PTR PDFs are encrypted, so
# they are read with PdfPig (lib/, from nuget.org) rather than by hand.
$clerk = "https://disclosures-clerk.house.gov/public_disc"
$ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Dobby/1.0"
$cacheDir = Join-Path ([IO.Path]::GetTempPath()) "dobby"
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

function Get-Url($url, $outFile) {
    for ($i = 1; $i -le 3; $i++) {
        $code = & curl.exe -s -L -A $ua -o $outFile -w "%{http_code}" $url
        if ($code -eq "200") { return }
        Write-Host "HTTP $code for $url (attempt $i)"
        Start-Sleep -Seconds (10 * $i)
    }
    throw "Download failed: $url"
}

$pdfLibLoaded = $false
function Get-PdfText($path) {
    if (-not $script:pdfLibLoaded) {
        # Load order matters on Windows PowerShell 5.1 (.NET Framework).
        $lib = Join-Path $root "lib"
        foreach ($n in "System.Runtime.CompilerServices.Unsafe", "System.Buffers", "System.Numerics.Vectors", "System.Memory",
                       "System.ValueTuple", "Microsoft.Bcl.HashCode", "UglyToad.PdfPig.Core", "UglyToad.PdfPig.Tokens",
                       "UglyToad.PdfPig.Tokenization", "UglyToad.PdfPig.Fonts", "UglyToad.PdfPig", "UglyToad.PdfPig.DocumentLayoutAnalysis") {
            [void][Reflection.Assembly]::LoadFrom((Join-Path $lib "$n.dll"))
        }
        $script:pdfLibLoaded = $true
    }
    $doc = [UglyToad.PdfPig.PdfDocument]::Open($path)
    try {
        return ($doc.GetPages() | ForEach-Object { [UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor.ContentOrderTextExtractor]::GetText($_) }) -join "`n"
    } finally { $doc.Dispose() }
}

function Get-FilingIndex {
    $years = @($etNow.Year); if ($etNow.Month -eq 1) { $years += $etNow.Year - 1 }
    $filings = @()
    foreach ($y in $years) {
        $zip = Join-Path $cacheDir "$($y)FD.zip"
        Get-Url "$clerk/financial-pdfs/$($y)FD.zip" $zip
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $entry = $z.Entries | Where-Object { $_.Name -eq "$($y)FD.xml" }
            $reader = New-Object IO.StreamReader($entry.Open())
            [xml]$xml = $reader.ReadToEnd(); $reader.Dispose()
        } finally { $z.Dispose() }
        foreach ($m in $xml.FinancialDisclosure.Member) {
            if ($m.FilingType -ne "P") { continue }
            $filings += [pscustomobject]@{
                docId = "$($m.DocID)"; year = $y; last = "$($m.Last)"; stateDst = "$($m.StateDst)"
                filed = [DateTime]::ParseExact("$($m.FilingDate)", "M/d/yyyy", $inv)
            }
        }
    }
    return $filings
}

# Amount brackets -> midpoint, matching how the size tiers are expressed.
function Amount-Value($amt) {
    $nums = @([regex]::Matches($amt, '\$([\d,]+)') | ForEach-Object { [double]($_.Groups[1].Value -replace ',', '') })
    if ($nums.Count -ge 2) { return ($nums[0] + $nums[1]) / 2 }
    if ($nums.Count -eq 1) { return $nums[0] }
    return 0
}

# Parses a PTR's text into trade objects shaped for Parse-Trade.
# Each row looks like: "<asset name> (TICKER) [ST] P 09/08/2026 09/09/2026 $1,001 - $15,000"
# followed by detail lines (filing status, owner account, and a description --
# which is where option strike/expiry is written).
function Parse-Ptr($text, $filing) {
    $rx = '\((?<tk>[A-Z][A-Z0-9.\-/]{0,7})\)\s*\[(?<at>[A-Z]{2})\]\s*(?<tx>P|S\s*\(partial\)|S|E)\s+(?<td>\d{2}/\d{2}/\d{4})\s+(?<nd>\d{2}/\d{2}/\d{4})\s+(?<amt>\$[\d,]+\s*-\s*\$[\d,]+|Over\s+\$[\d,]+|\$[\d,]+)'
    $ms = [regex]::Matches($text, $rx)
    $rows = @()
    for ($i = 0; $i -lt $ms.Count; $i++) {
        $m = $ms[$i]
        $tailEnd = if ($i + 1 -lt $ms.Count) { $ms[$i + 1].Index } else { $text.Length }
        $detail = ($text.Substring($m.Index + $m.Length, $tailEnd - $m.Index - $m.Length) -replace '\s+', ' ').Trim()
        # Keep only the option description (if any); the rest is account names and page boilerplate.
        $desc = ""
        if ($detail -match '(?i)((?:purchased|bought|sold|sale of|exercised)\s+[\d,]+\s+(?:call|put)\s+options?.*?\d{1,2}/\d{1,2}/\d{2,4})') { $desc = $Matches[1] }
        elseif ($detail -match '(?i)(contribution|gift|donat\w*)') { $desc = $Matches[1] }
        $assetType = $m.Groups["at"].Value
        $tx = $m.Groups["tx"].Value
        $txType = if ($tx -eq "P") { "buy" } elseif ($tx -like "S*") { "sell" } else { "exchange" }
        if ($assetType -notin "ST", "OP", "EF") { $txType = "unsupported asset type [$assetType]" }
        $rows += [pscustomobject]@{
            _txId = "$($filing.docId)-$($i + 1)"
            txDate = [DateTime]::ParseExact($m.Groups["td"].Value, "MM/dd/yyyy", $inv).ToString("yyyy-MM-dd")
            pubDate = $filing.filed.ToString("yyyy-MM-ddT13:00:00Z")
            txType = $txType
            value = Amount-Value $m.Groups["amt"].Value
            issuer = [pscustomobject]@{ issuerTicker = ($m.Groups["tk"].Value -replace '/', '.') }
            comment = ("[$assetType] $($m.Groups['amt'].Value -replace '\s+', ' ') $desc").Trim()
        }
    }
    return $rows
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

$seenPath = Join-Path $stateDir "filings_seen.json"
$seen = @{}
if (Test-Path $seenPath) { foreach ($s in (Get-Content $seenPath -Raw | ConvertFrom-Json)) { $seen["$($s.docId)"] = $s } }
function Save-Seen {
    if ($DryRun) { return }
    ConvertTo-Json -InputObject @($seen.Values | Sort-Object docId) -Depth 3 | Out-File -FilePath $seenPath -Encoding utf8
}

$index = Get-FilingIndex
$newCount = 0
foreach ($pol in $cfg.politicians) {
    $mine = @($index | Where-Object { $_.last -eq $pol.last -and $_.stateDst -eq $pol.stateDst } | Sort-Object filed)
    $raw = @()
    foreach ($f in $mine) {
        if ($seen.ContainsKey($f.docId)) { continue }
        $ageDays = ($etNow.Date - $f.filed).TotalDays
        $limitDays = if ($firstRun) { $cfg.firstRunBackfillDays } else { $cfg.maxDisclosureAgeDays }
        $entry = [ordered]@{ docId = $f.docId; politician = $pol.name; filed = $f.filed.ToString("yyyy-MM-dd"); trades = 0; note = "" }
        if ($ageDays -gt $limitDays) {
            $entry.note = "older than $limitDays-day window, not copied"
        } else {
            $pdf = Join-Path $cacheDir "$($f.docId).pdf"
            Get-Url "$clerk/ptr-pdfs/$($f.year)/$($f.docId).pdf" $pdf
            $text = Get-PdfText $pdf
            $rows = @(Parse-Ptr $text $f)
            if ($rows.Count -eq 0) { $entry.note = if ($text.Trim().Length -lt 50) { "scanned paper filing, no readable text" } else { "no stock/option rows found" } }
            $entry.trades = $rows.Count
            $raw += $rows
            Write-Host "$($pol.name): filing $($f.docId) ($($entry.filed)) -> $($rows.Count) trades $($entry.note)"
        }
        $seen[$f.docId] = $entry
    }
    Write-Host "$($pol.name): $($mine.Count) filings in the Clerk index, $($raw.Count) new trades"
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
Save-Seen

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
Write-Host "Dobby run complete."
