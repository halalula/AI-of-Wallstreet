# Stacy

Trades one position at a time in her own Alpaca **paper** account. When a trade closes, she goes back to
scanning the charts for the next entry. She runs on GitHub Actions (`.github/workflows/stacy.yml`) every 5
minutes during market hours.

## Finding an entry
Stacy scans the `watchlist` (TSLA for now) between 9:45 AM and 3:30 PM ET, using completed 15-minute candles.
She enters only when **all** of these hold:

| Check | Meaning |
|---|---|
| Daily trend | The last daily close is above its 20-day average, and that average is rising. |
| VWAP | The price is above today's volume-weighted average price. |
| Momentum | The 9-EMA is above the 21-EMA, and RSI(14) is between 45 and 70 (not overbought). |
| Candle trigger | The last 15-minute candle is a bullish engulfing, a hammer at the 21-EMA, or a green breakout above the previous 4 candles' highs. |

She makes no new entry within 30 minutes of an exit, and never while the account holds any position.
Every check is in `stacy_config.json`.

## Managing the trade
The dollar amounts are set from account equity at each entry. On $10,000 they are:

| Rule | What happens |
|---|---|
| Entry | Buy 90% of equity in whole shares at market. |
| Floor | A GTC stop order at Alpaca sells everything if the total loss reaches 1% ($100). |
| Ladder in | Once, if the first lot is down 0.5% ($50), buy half as many shares again. The floor then moves so the loss on **all** shares is still capped at $100. |
| Trailing floor | When open profit reaches 2% ($200), the floor moves to 5% below the price. Each further 5% climb moves it up again. It never moves down. |

The stop becomes a market order when it is hit, so a fast drop or an overnight gap can lose more than the floor.
The ladder-in may use margin, because 90% of the cash is already in the first buy. These are mechanical rules,
not a prediction.

## Files
| File | Purpose |
|---|---|
| `stacy.ps1` | Scans, enters and manages the trade. `-DryRun` plans without trading. `-Summary` prints the rules, the setup checks or trade levels, orders and positions. |
| `stacy_config.json` | Watchlist, entry window, indicator ranges and rule percentages. |
| `state/stacy_state.json` | The current phase (`scanning`, `entry_submitted`, `active`) and the trade's levels. |
| `logs/stacy_log.csv` | Every entry, order, floor change and closed trade. |

Keys come from `Stacy/.env` (gitignored) locally, and from the `STACY_APCA_API_KEY` and `STACY_APCA_API_SECRET`
repo secrets on GitHub.
