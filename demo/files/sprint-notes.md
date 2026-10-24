# Platform sprint 42 — notes

Goal: ship the token refresh refactor and cut auth latency below 150 ms p95.

## Done
- TokenRefresher class with an explicit clock; 4 new tests for expiry edges.
- p95 auth latency 182 ms → 141 ms in staging.

## Open
- Flaky test in payments (retries once, passes). Owner: Sam. Due Friday.
- Docs for the new refresh flow. Owner: Lee.

## Decisions
- Keep the public API unchanged; deprecate refresh_v1 in sprint 44.
- Rollout behind a flag: 10% Monday, 50% Wednesday, 100% the following Monday.
