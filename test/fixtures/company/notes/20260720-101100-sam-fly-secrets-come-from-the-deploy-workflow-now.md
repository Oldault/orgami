---
id: 20260720-101100-sam-fly-secrets-come-from-the-deploy-workflow-now
author: sam
date: 2026-07-20T10:11:00Z
repo: api
supersedes: 20260415-140200-sam-fly-deploys-need-the-secrets-set-first
tags: [deploy]
---

Since api#498 the deploy workflow sets the fly secrets from the GitHub environment before `fly deploy`, so nothing has to be typed by hand. A new secret goes into the `production` environment in GitHub, not into fly directly.
