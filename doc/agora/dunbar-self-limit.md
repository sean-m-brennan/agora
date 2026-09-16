# Dunbar self-limit — Phase 2 exit artifact

**Claim (SOCIAL_APP_PLAN.md §6, Phase 2 exit):** *the graph demonstrably
self-limits near ~150 strong ties in simulation.*

This is the **simulation** half of that exit criterion. (The **pilot-cohort**
half — the same limit observed in a real deployment — remains a field exercise.)

## What is demonstrated

The active strong-tie network self-limits near Dunbar's ~150 **even though the
raw connection list grows without bound** — because the limit is not a cap on
the friend list, it emerges from the attention budget (§3.3):

```
cost(edge) = base_cost · (1 / p(d)) · (1 / recency)
```

A co-located, freshly-tended tie costs ≈ `base_cost`, so `B / base_cost ≈ 150`
of them fit. A distant or neglected tie costs multiples of that (recency floored
⇒ up to ~50×), so it falls **over the budget line** — flagged and faded in the
UI, **never severed**. An agent with finite attention can therefore keep only
~`B` ties affordable, however many people it meets.

## How it is run

`test/sim/dunbar_sim.dart` drives the **real shipping models** — `tieStrength`,
`edgeCost`, `BudgetLedger` over real `AgoraPeer`s — no daemon, no FFI, fully
deterministic given a seed. Each simulated day the agent:

1. **meets** `meetsPerDay` new people (unbounded intake; a `localFraction` are
   co-located, the rest distant with an RTT-derived proximity < 1);
2. **tends** its strongest ties (refreshes their recency) up to `tendPerDay` —
   set generously (well above `B`) so the binding constraint is the attention
   **budget**, not raw touch-count. A less-engaged agent (lower throughput)
   plateaus *lower*;
3. reads the `BudgetLedger` and records the **affordable** strong-tie count
   (strong ties within `B`) — the active network, the quantity that self-limits.

`test/dunbar_self_limit_test.dart` asserts the behaviour and prints the curve.

## Result

Default engaged agent (`meetsPerDay=8`, `localFraction=0.85`, `B=150`), 2 years:

```
  day  connections  strong  affordable  utilization
    0            8       8           8         0.05
   60          488     410         150         2.73
  120          968     500         150         3.33
  ...
  729         5840     500         150         3.33
```

- **Active network locks at ~150.** Affordable strong ties ramp from 8 to 150
  over ~30 days, then hold at **150** (spread 0 over the final 120 days) while
  connections grow to **5,840** — the active network is < 3 % of everyone met.
- **`B` is the knob, not a hard cap.** Doubling the budget (`B=300`) doubles the
  plateau to **300** (ratio 2.00): the ~150 is emergent, not decreed.
- **Distance is the discount.** An all-local population plateaus at **150**; an
  all-distant one at **~26** — distant ties cost more budget, so fewer fit.
- **Advisory pressure, not severance.** At steady state the agent *tends* ~500
  strong ties but only **150** are affordable (utilization 3.33); the other ~350
  are flagged over-budget — the "stretched" state the UI fades, never cutting a
  tie automatically (the locked Phase-2 decision).

## Reproduce

```bash
cd lib/muudd/apps/agora
flutter test test/dunbar_self_limit_test.dart
```
