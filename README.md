# Doroosak | دروسك

**Learn from home. Grow with knowledge.**

Live one-to-one lessons connecting Arab and Yemeni families in the United States with qualified teachers from Yemen: Quran, Islamic Studies, Arabic, English, and any subject a family requests.

## Repository layout

| Path | What it holds |
| --- | --- |
| `supabase/migrations/` | The database: schema, booking rules, slot calculation, Row Level Security |
| `supabase/tests/` | Tests that run against real Postgres (timezones, double-booking, permissions) |
| `supabase/local/` | Local-only shims that let the migrations run on plain Postgres. Never deploy these |
| `app/` | Flutter app (parents, children, teachers; admin as a web build) |
| `app/lib/theme/tokens.dart` | Design tokens from the approved screens: colors, type, radii, spacing |
| `docs/` | Architecture and decisions |

## Core rules the code enforces

1. **Time.** Every instant is stored in UTC. Teacher availability is stored as local wall time plus an IANA zone (`Asia/Aden`) and converted per date by Postgres's IANA database. No fixed offsets anywhere.
2. **No double-booking.** Two Postgres exclusion constraints make overlapping bookings for the same teacher (lesson + 10-minute buffer) or the same child impossible, whatever the app does.
3. **Families.** The parent is the account holder; children are learner profiles under that account. A parent can only see and book for their own children.
4. **Money.** Prices and the platform fee come from the `price_list` table, are computed on the server, and are snapshotted on each booking. Ledger transactions must balance to zero.

## Running the database tests

Requires Postgres 16 and Python 3.11+.

```bash
pip install psycopg2-binary pytest
cd supabase/tests
PGHOST=/tmp PGUSER=postgres python -m pytest -q
```

The suite creates a throwaway database, applies the migrations, and runs:

- **Timezones:** rule expansion compared with Python's `zoneinfo` (an independent IANA implementation) for 24 months, 3 teacher zones and 5 lesson times; student-side display checked in 9 zones with a round trip back to UTC; daylight-saving gap and overlap cases.
- **Double-booking:** real concurrent connections racing for the same slot (2 connections × 100 runs, 8 connections × 50 runs, overlapping-but-different slots, the app booking function, and the buffer).
- **Access:** parents see only their children, can't book for others, can't write bookings directly; teachers can't approve themselves; the ledger must balance.

GitHub Actions runs the same suite on every push.
