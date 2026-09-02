---
id: 20260711-223000-priya-nightly-export-times-out-past-2m-rows
author: priya
date: 2026-07-11T22:30:00Z
repo: warehouse-jobs
tags: [incident]
---

The nightly export locks the orders table for the whole run once it passes about two million rows, and the API's checkout writes queue behind it until the 15-minute statement timeout fires. Run it in batches of 200k (`EXPORT_BATCH=200000`) or the morning on-call gets paged at 03:10.
