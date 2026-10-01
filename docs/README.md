# Docs

- **Architecture (living document):** https://claude.ai/code/artifact/297e7642-e547-4346-8be4-7c1061f437d5
- **MVP screen designs:** https://claude.ai/artifact/GG7zULraSaz2ditHiVSCME

## Decisions log

| Date | Decision |
| --- | --- |
| 2026-10-01 | Parent is the account holder; children are profiles under it. Teens may get linked sign-ins later. |
| 2026-10-01 | Teacher payouts at launch are manual remittances via a trusted person in the US, recorded in `payouts`. |
| 2026-10-01 | Timezone tests compare against an independent IANA implementation, never hard-coded "before/after November" logic. |
| 2026-10-01 | Booking holds are serialized per teacher (advisory lock) so racing parents get a clean "slot taken"; exclusion constraints remain the final guarantee. |
| 2026-10-01 | For zones with DST: a lesson inside the spring-forward gap moves forward by the skipped hour; a repeated fall-back time resolves to one lesson. |
