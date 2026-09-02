---
id: 20260301-080000-sam-billing-api-rollback-is-kamal-rollback
author: sam
date: 2026-03-01T08:00:00Z
repo: billing-api
tags: [rollback]
---

`kamal rollback <sha>` on billing-api keeps the previous container image around for 24 hours; after that a rollback is a redeploy of the old tag.
