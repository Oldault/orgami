---
id: 20260805-163000-dana-carmax-style-empty-result-in-the-stripe-export
author: dana
date: 2026-08-05T16:30:00Z
repo: warehouse-jobs
topic: broken-export
tags: [pattern]
---

The Stripe payouts export returned an empty list instead of raising when the API key was rotated, so the job logged success with zero rows for three nights. Made `Exports::Base#fetch` raise on an empty page when the previous run had rows, and added the row count to the Slack summary. Verified with `bundle exec rspec spec/exports/stripe_spec.rb`.
