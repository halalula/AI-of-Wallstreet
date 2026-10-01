# Stacy

Makes one staggered trade in TSLA in her own Alpaca **paper** account. She runs on GitHub Actions
(`.github/workflows/stacy.yml`) every 5 minutes during market hours.

## Rules
The dollar amounts are set from account equity when the trade opens. On $10,000 they are:

| Rule | What happens |
|---|---|
| Entry | Buy 90% of equity in whole shares at market. |
| Floor | A GTC stop order at Alpaca sells everything if the total loss reaches 1% ($100). |
| Ladder in | Once, if the first lot is down 0.5% ($50), buy half as many shares again. The floor then moves so the loss on **all** shares is still capped at $100. |
| Trailing floor | When open profit reaches 2% ($200), the floor moves to 5% below the price. Each further 5% climb moves it up again. It never moves down. |

The stop becomes a market order when it is hit, so a fast drop or an overnight gap can lose more than $100.
The ladder-in may use margin, because 90% of the cash is already in the first buy.

## Files
| File | Purpose |
|---|---|
| `stacy.ps1` | Runs the trade. `-DryRun` plans without trading. `-Summary` prints the rules, levels, orders and position. |
| `stacy_config.json` | Symbol and rule percentages. |
| `state/stacy_state.json` | Entry, floor, ladder and trailing state. Delete it after a trade closes to start a new one. |
| `logs/stacy_log.csv` | Every order and floor change. |

Keys come from `Stacy/.env` (gitignored) locally, and from the `STACY_APCA_API_KEY` and `STACY_APCA_API_SECRET`
repo secrets on GitHub.
