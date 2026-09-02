---
id: 20260415-140200-sam-fly-deploys-need-the-secrets-set-first
author: sam
date: 2026-04-15T14:02:00Z
repo: api
tags: [deploy]
---

A fresh fly app has no secrets. Run `fly secrets set DATABASE_URL=... REDIS_URL=...` before the first `fly deploy`, or the release command fails on migrations with a connection refused that looks like a network problem.
