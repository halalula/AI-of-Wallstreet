# Dobby

Copies Nancy Pelosi's disclosed trades from [Capitol Trades](https://www.capitoltrades.com/politicians/P000197)
into a separate Alpaca **paper** account. It runs on GitHub Actions (`.github/workflows/dobby.yml`)
every 30 minutes during market hours, and a report runs at 5:15 PM ET.

| File | Purpose |
|---|---|
| `dobby.ps1` | Scrapes her trades, copies new ones, retries unfilled orders, closes options near expiry. `-DryRun` plans without trading. |
| `dobby_report.ps1` | Account value vs. SPY since day one (`logs/equity_history.csv`), positions, recent activity. |
| `dobby_config.json` | Who to copy, position sizing tiers, caps, options rules. |
| `state/processed_trades.json` | Every disclosure the bot has seen and what it did with it. |
| `logs/copy_log.csv` | Each order and skip, with the reason. |

## How trades are copied

- **Timing:** members of Congress have up to 45 days to disclose, so every copy is late by design. The bot acts on a disclosure the first market-hours run after Capitol Trades publishes it.
- **Sizing:** her size bracket maps to a share of our equity (for example, $1M–$5M → 10%). No single ticker can be more than 25% of the account, and 5% stays in cash.
- **Options:** the bot buys the exact contract (same ticker, expiry, strike, call or put) with a limit order at the ask. Her contracts are usually deep in-the-money LEAPS that cost $7k–$17k each. When one contract won't fit the budget, it buys the stock as a proxy and sells that proxy when she sells the option.
- **Sells:** when she sells, we close our whole position in that name. Her filings don't show what fraction of her holding she sold.
- **Exercises:** the bot sells the matching contract and buys the stock with the proceeds.
- **Skipped:** donations, private funds and LLCs without a ticker, and "exchange" transactions.

## Run locally

```powershell
.\dobby.ps1 -DryRun
.\dobby_report.ps1
```

Keys go in `Dobby/.env` (gitignored) locally, and in the repo secrets `COPY_APCA_API_KEY_ID` and `COPY_APCA_API_SECRET_KEY` for GitHub Actions.
