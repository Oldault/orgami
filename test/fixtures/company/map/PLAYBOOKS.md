# acme — how this kind of work is done

A runbook says how one repository is run and shipped. A playbook says
how one *kind of change* is made in it — written from the instances the
team recorded while making it, and rewritten whenever another lands.

| Repository | Topic | Instances | Written |
|---|---|---|---|
| warehouse-jobs | [broken export](playbooks/warehouse-jobs--broken-export.md) | 2 | 2026-08-06 |

Record the next instance while it is fresh:

```bash
orgami note --repo <repo> --tag pattern --topic <topic> "what the shape was, and what worked"
```
