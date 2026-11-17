# Screenshot checklist

Screenshots for the portfolio write-up. Nothing here is captured automatically: each
item says what has to be on screen, and any manual setup it needs.

> **All data in these screenshots is synthetic demo data for a portfolio project.**
> The 50 accounts are invented Indian companies; no real customer, person or contract
> appears anywhere in this org. Every figure on screen comes from a SOQL query against
> those seeded records, and every AI insight is either produced by the live model or
> labelled **Rule based**.

Run the seed and demo scripts first:

```bash
sf apex run --file scripts/apex/seed-data.apex --target-org RenewalIQ
sf apex run --file scripts/apex/demo-scenario.apex --target-org RenewalIQ
sf apex run -f <(echo "RIQ_NightlyScoreScheduler.scheduleNightly();") --target-org RenewalIQ
```

Assign yourself `RIQ_Admin` (or `RIQ_CSM`) so the Recalculate and log-signal actions are
visible:

```bash
sf org assign permset --name RIQ_Admin --target-org RenewalIQ
```

---

## 1. Command Center — the money shot

- **Screen:** RenewalIQ app → **Command Center** tab (App Page `RIQ_Command_Center`).
- **Must show:** four KPI tiles (Total ARR, ARR at risk, Average score, Renewals due),
  the status distribution donut with its legend, and the accounts table sorted by score.
- **Setup:** renewal window **Next 90 days**, owner **All owners**, status
  **At Risk + Critical**.
- **Caption material:** "One screen answers *how bad is it* (KPIs), *where* (distribution)
  and *who* (drill-down), and the table sorts and filters **server side**."

## 2. Command Center — filtered and sorted

- **Must show:** the same page after choosing a specific owner, status **Critical**, and
  sorting by **ARR** descending.
- **Caption material:** "Filters round-trip to Apex; the sort is a whitelisted field map,
  not a `Database.query` string."

## 3. Command Center — Chart.js unavailable (fallback)

- **How:** temporarily block `https://<org>.lightning.force.com/resource/.../chartjs` in
  DevTools (Request blocking), then reload the page.
- **Must show:** the pure SVG donut with the same segments, counts and legend.
- **Caption material:** "Chart.js is a static resource loaded with `loadScript`; under
  Lightning Web Security the global can be hidden, so the component falls back to an
  SVG donut built from the same data. No CDN, and no blank panel."

## 4. Command Center — row action

- **Must show:** the row action menu open on an account with **Recalculate**.
- **Then:** a success toast reading `Recalculated <account> · score N · <status>`.
- **Caption material:** "The row action calls the same non-cacheable Apex method the
  record page uses, then reloads the KPIs so the totals stay honest."

## 5. Account record page — health card

- **Screen:** the **Phase 4 Demo - Initech Systems** account (critical, renewal in 5 days).
- **Must show:** the gauge with the score, the status badge, churn probability, ARR,
  contract end, days to renewal, the 12-point sparkline and the **top three drivers**
  with their point penalties.
- **Caption material:** "The drivers are the receipt for the number: each one is a
  weighted, time-decayed signal, and the JSON that stores them is parsed defensively."

## 6. Account record page — signal logger

- **Must show:** the **Log a health signal** form with a type chosen, severity **4**, a
  date and a note.
- **Then:** the success toast plus the blue **"Score updating… the recalculation runs in
  the background"** state.
- **Caption material:** "Scoring is asynchronous, so the UI never fakes an instant new
  score: it shows that work is in flight, then refreshes the card over Lightning Message
  Service once the Queueable has run."

## 7. Signal logger — validation

- **How:** submit with no signal type, or with a date in the future.
- **Must show:** the field-level message, and no request in the network panel.
- **Caption material:** "Client validation is only for speed; `logSignal` re-validates
  every field in Apex because the browser is not a security boundary."

## 8. Read-only user — actions refused

- **How:** assign `RIQ_Read_Only` to a second user, log in as them, open the same
  critical account.
- **Must show:** the Command Center without the ability to act, and (if the buttons are
  dropped by the component) the same result when the Apex method is called directly: a
  friendly `AuraHandledException` message, not a raw stack trace or a silent no-op.
- **Caption material:** "Hiding a button is not a permission model. Custom Permissions
  are checked in Apex, so a hand-crafted `recalculate` call fails the same way."

## 9. Live update — platform event

- **How:** open the Command Center in one window, then run:
  `sf apex run -f <(echo "RIQ_HealthScoreRecalculator.process(new Set<Id>{'<accountId>'});")`
  on an account whose band will move.
- **Must show:** the toast `Health status changed · <from> → <to> · score N` and refreshed
  KPI tiles without a page reload.
- **Caption material:** "empApi subscribes to `/event/RIQ_Health_Status_Change__e`, and
  `disconnectedCallback` unsubscribes, so navigating away does not leak a subscription."

## 10. Playbook output for the demo account

- **Screen:** the same critical account's **Activity** related list.
- **Must show:** the open `Executive outreach: …` task and the open `Renewal`
  opportunity created by the subscriber, with a real **Created By** name.
- **Caption material:** "The event is consumed by a named subscriber user, so the audit
  trail says who did the work instead of 'Automated Process'."

## 11. The AI insight panel (Phase 5)

- **Screen:** the health score card of a risky account, after **Generate AI insight**.
- **Must show:** the **Insight** heading with its source badge, the summary paragraph, the
  **Next best action** block and up to three risk reasons, plus the generated timestamp.
- **Two shots, both useful:** one with `RIQ AI Config.Default.Is_Enabled__c` **on** and a real
  key (badge reads **AI generated**), and one with it **off** (badge reads **Rule based**).

  The pair is the caption material: "the same screen makes it obvious whether a machine
  wrote the sentence or the rules did."

---

## What is *not* verified in this repository

The components were deployed to the org and their bundles compiled, and the behaviour is
covered by 53 Jest tests (rendering, filters, sort, row action, recalculate, insight panel,
validation, toast, subscribe/unsubscribe, empty and error states) plus the Apex tests behind
them. Nobody has clicked through the rendered pages in a browser as part of the build, so
the visual items above — gauge proportions, donut angles, sparkline shape, responsive
wrapping, the insight panel's wrapping at narrow widths — are the ones to confirm when the
screenshots are taken.
