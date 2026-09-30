# Dobby

Copies the disclosed stock trades of **Rep. David Taylor (OH-02)**, **Rep. Cleo Fields (LA-06)** and
**Rep. Jared Moskowitz (FL-23)** into a separate Alpaca **paper** account. It runs on GitHub Actions (`.github/workflows/dobby.yml`) every 30 minutes
during market hours, and a report runs at 5:15 PM ET.

## Why these two
I replayed 2 years of trades for about 50 actively trading members of Congress. Each purchase was bought on the
day it became public and sold when the sale was disclosed, and duplicate lots were removed. Taylor and Fields
fit the "active, many small-to-medium wins" profile best:

| | Buys/month | Trades that made money | Avg vs SPY per trade | Same, without the 2 best trades |
|---|---|---|---|---|
| Taylor, last 12 months | 6.6 | 70% | +0.9% | +0.1% |
| Fields, 2 years | 3.9 | 71% | +9.8% | +4.7% |

Moskowitz was added on 2026-09-30 to make Dobby trade more often: 6.5 buys/month, +4.0% vs SPY per trade over
2 years and +17.9% in the most recent year, though his median trade lagged SPY (a few big winners carried him).

Most other very active traders (Khanna, McCaul, Cisneros, McClain) did slightly worse than SPY. Pelosi and
Moskowitz beat it mostly through a couple of huge winners. Past results don't predict future ones.

## Data source
The **official House Clerk disclosures** at disclosures-clerk.house.gov. Every morning around 9 AM ET, Dobby
reads the Clerk's filing index and downloads each new Periodic Transaction Report PDF for these two members. It
reads the PDFs with [PdfPig](https://github.com/UglyToad/PdfPig) (`lib/`, from nuget.org). Filings show up here
a few days before Capitol Trades posts them. Capitol Trades also blocks GitHub's servers, so it can't be used.

| File | Purpose |
|---|---|
| `dobby.ps1` | Reads new filings, copies trades, retries unfilled orders, closes options near expiry. `-DryRun` plans without trading. |
| `dobby_report.ps1` | Account value vs. SPY since day one (`logs/equity_history.csv`), positions, recent activity. |
| `dobby_config.json` | Who to copy (House last name + state/district), sizing tiers, caps, options rules. |
| `state/filings_seen.json` | Every filing Dobby has read. |
| `state/processed_trades.json` | Every trade in those filings and what Dobby did with it. |
| `logs/copy_log.csv` | Each order and skip, with the reason. |

## How trades are copied
- **Timing:** members of Congress have up to 45 days to disclose, so every copy is late by design.
- **Sizing:** their amount bracket maps to a share of our equity. Their usual $1K–$15K trades become 6% each, and larger brackets scale up to 36% (tripled on 2026-09-30). No single ticker can be more than 25% of the account, and 5% stays in cash.
- **Sells:** when they sell, we close our whole position in that name. Sells of stocks we don't hold are skipped.
- **Options:** the bot buys the exact contract (ticker, expiry, strike, call or put) with a limit order at the ask. If one contract won't fit the budget, it buys the stock as a proxy.
- **Skipped:** bonds, funds and other non-stock assets, exchanges, gifts and donations, and scanned paper filings that have no readable text.

## Run locally
```powershell
.\dobby.ps1 -DryRun
.\dobby_report.ps1
```
Keys go in `Dobby/.env` (gitignored) locally, and in the repo secrets `COPY_APCA_API_KEY` and `COPY_APCA_API_SECRET` for GitHub Actions.
