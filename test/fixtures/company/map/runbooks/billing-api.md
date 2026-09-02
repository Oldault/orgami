# billing-api — runbook

Go · Go module · private

Payments, invoices and webhook delivery

<sub>Derived from the scan of 2026-08-18. Nothing here was written by a model.</sub>

## Run it

Needs go 1.24, go.

First time here:

```bash
go mod download
```

- **test** — `make test`
- **build** — `make build`
- **check** — `make lint`

It reads 5 environment variables: `DATABASE_URL`, `PADDLE_API_KEY`, `SQS_QUEUE_URL`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_URL`.

Of those, `DATABASE_URL`, `SQS_QUEUE_URL`, `STRIPE_WEBHOOK_URL` point at something outside this repository.

## How it ships

| Workflow | On | Environment |
|---|---|---|
| `.github/workflows/ship.yml` (ship) | workflow_dispatch | production |

Deploys to `billing.acme.com` (config/deploy.yml:12) with kamal.

## Rolling it back

> `kamal rollback <sha>` on billing-api keeps the previous container image around for 24 hours; after that a rollback is a redeploy of the old tag.
> <sub>sam, 2026-03-01</sub>

## Where it lives

- `billing.acme.com` — config/deploy.yml:12

## What it drags with it

- warehouse-jobs — 3 weeks / 5 days, dana, priya <sub>inferred</sub>

## Who has been in here

dana, priya — from the merged pull requests of the last six weeks.
