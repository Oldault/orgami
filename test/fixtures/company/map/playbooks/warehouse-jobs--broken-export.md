# warehouse-jobs — broken export

<sub>Written by `claude-opus-5` on 2026-08-06 from 2 recorded
instance(s) and the merged pull requests that match. Unlike the rest of
the map, the prose below was not derived — the evidence it was written
from is printed at the end, and disagreement between the two means the
evidence is right.</sub>

## When you are in this case

An export job reports success and writes nothing, or stops writing without an error anyone saw. Both recorded instances were an upstream credential change the job swallowed (20260726-093000-priya-google-sheets-export-stopped-after-the-service-account-key-expired, 20260805-163000-dana-carmax-style-empty-result-in-the-stripe-export).

## Check first

1. The row count in the last Slack summary — zero rows after a run that had rows is the signal (20260805-163000-dana-carmax-style-empty-result-in-the-stripe-export).
2. Whether a key or token for that export was rotated in the last week (20260726-093000-priya-google-sheets-export-stopped-after-the-service-account-key-expired).

## The procedure

1. Rotate or restore the credential where it lives — SSM under `/warehouse/` for service accounts (20260726-093000-priya-google-sheets-export-stopped-after-the-service-account-key-expired).
2. Make the export raise rather than log on auth errors and on an empty page after a non-empty run (`Exports::Base#fetch`) (20260805-163000-dana-carmax-style-empty-result-in-the-stripe-export).
3. Add the row count to the summary if the export does not report one yet.

## Traps

- A 401 caught and logged at warning level looks like success in the dashboard (20260726-093000-priya-google-sheets-export-stopped-after-the-service-account-key-expired).

## How you know it worked

`bundle exec rspec spec/exports/<name>_spec.rb`, then `bin/export <name> --dry-run` shows a non-zero row count (both instances).

## Not established

TODO — the evidence does not say how to verify a Sheets export end to end without writing to the production sheet.

---

## What this was written from

```
REPOSITORY: warehouse-jobs
TOPIC: broken-export

HOW THE REPOSITORY RUNS
test: bundle exec rspec
setup: bin/setup

THE INSTANCES — notes recorded while this work was done, oldest first
- 20260726-093000-priya-google-sheets-export-stopped-after-the-service-account-key-expired (priya, 2026-07-26): The Sheets export stopped writing after the service account key expired; the job caught the 401 and logged a warning nobody read. Rotated the key in `infra` (SSM `/warehouse/sheets-key`), made the export fail loudly on auth errors, and confirmed the next run with `bin/export sheets --dry-run`.
- 20260805-163000-dana-carmax-style-empty-result-in-the-stripe-export (dana, 2026-08-05): The Stripe payouts export returned an empty list instead of raising when the API key was rotated, so the job logged success with zero rows for three nights. Made `Exports::Base#fetch` raise on an empty page when the previous run had rows, and added the row count to the Slack summary. Verified with `bundle exec rspec spec/exports/stripe_spec.rb`.

MERGED PULL REQUESTS THAT LOOK LIKE THE SAME WORK
- warehouse-jobs#89 — Move the nightly export to the jobs runner <sub>dev-two, 2026-08-14</sub>
```

Wrong, or out of date? `orgami note --repo warehouse-jobs --tag pattern --topic broken-export "…"`
records the next instance, and `orgami playbook warehouse-jobs --topic broken-export` rewrites this.
