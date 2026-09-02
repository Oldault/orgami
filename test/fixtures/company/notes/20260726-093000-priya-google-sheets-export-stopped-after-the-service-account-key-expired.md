---
id: 20260726-093000-priya-google-sheets-export-stopped-after-the-service-account-key-expired
author: priya
date: 2026-07-26T09:30:00Z
repo: warehouse-jobs
topic: broken-export
tags: [pattern]
---

The Sheets export stopped writing after the service account key expired; the job caught the 401 and logged a warning nobody read. Rotated the key in `infra` (SSM `/warehouse/sheets-key`), made the export fail loudly on auth errors, and confirmed the next run with `bin/export sheets --dry-run`.
