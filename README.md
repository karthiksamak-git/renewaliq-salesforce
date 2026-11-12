# RenewalIQ — Customer Health & Renewal Command Center

A Salesforce portfolio project that scores every customer Account's health (0–100)
from configurable rules, predicts churn risk, creates renewal work automatically,
and surfaces it all in an LWC dashboard for Customer Success Managers.

**Stack:** Salesforce DX (source format, API 62.0) · Apex (trigger handler +
selector/service layers) · Custom Metadata driven rules · LWC + Jest · Queueable /
Batch / Schedulable async · LLM callout for AI account summaries.

## Why this project exists

Renewal risk is usually spotted too late, in a spreadsheet, after the customer has
already decided to leave. RenewalIQ makes the score a first-class Salesforce field:
every signal (escalation, usage drop, missed QBR, sponsor departure, late payment,
detractor NPS, expansion) feeds a weighted, time-decayed score. Rules and
thresholds live in Custom Metadata, so Customer Success ops can tune the model
without a deployment.

## Architecture at a glance

| Layer            | Responsibility                                    | Example                                       |
| ---------------- | ------------------------------------------------- | --------------------------------------------- |
| Trigger          | One per object, delegation only                   | `RIQ_HealthSignalTrigger`                     |
| Handler / Domain | Trigger context routing, record-level validation  | `RIQ_HealthSignalTriggerHandler`              |
| Selector         | All SOQL for an SObject, `USER_MODE` by default   | `RIQ_HealthSignalSelector`                    |
| Service          | Business logic, bulk-safe, transaction boundaries | `RIQ_HealthScoreService`                      |
| Async            | Off-transaction work                              | `RIQ_HealthScoreRecalculator` (Queueable)     |
| Batch / Cron     | Whole-book recalculation, time-decayed scores     | `RIQ_NightlyScoreBatch`, `RIQ_NightlyScoreScheduler` |
| Domain event     | "This account's band moved", after commit         | `RIQ_Health_Status_Change__e`                 |
| Subscriber       | Turns an event into work, idempotently            | `RIQ_PlaybookService`                         |
| Declarative      | Notification + feed post, admin-editable          | `RIQ_Account_Critical_Alert` (Flow)           |
| Config           | Thresholds and weights, no hardcoded numbers      | `RIQ_Scoring_Rule__mdt`, `RIQ_Threshold__mdt`, `RIQ_Batch_Config__mdt` |
| UI               | LWC dashboard + record components                 | `riqHealthDashboard`                          |

### How the score is calculated

```
score = clamp(100 - Σ(baseWeight × severity × decayFactor), 0, 100)
decayFactor = clamp(1 - daysSinceOccurred / decayDays, 0, 1)
```

One formula covers everything: a penalty is a positive `Base_Weight__c`, a credit
(such as Positive Expansion) is a negative one. The score is then banded by
`RIQ_Threshold__mdt` (highest `Min_Score__c` first), and churn probability is
derived from the score plus a renewal-proximity bonus. Every recalculation appends
a `RIQ_Score_History__c` row whose `Drivers__c` JSON explains the number.

Trigger → handler → `Queueable` → service: signals never calculate a score inline,
so a 200-record load stays bulk-safe and well inside governor limits.

## The automation layer (Phase 3)

```
RIQ_Health_Signal__c ──trigger──▶ Queueable ─┐
                                            ├─▶ RIQ_HealthScoreRecalculator.process(Set<Id>)
RIQ_NightlyScoreScheduler ─▶ Batch ─────────┘        │
                                                     ├─▶ Account score/status/churn
                                                     ├─▶ RIQ_Score_History__c
                                                     └─▶ RIQ_Health_Status_Change__e (only on a real band change)
                                                                  │
                                                    RIQ_HealthStatusChangeTrigger (named subscriber user)
                                                                  │
                                                          RIQ_PlaybookService
                                                            ├─▶ Task "Executive outreach: <account>"
                                                            └─▶ Opportunity (Type = Renewal) when inside 120 days

Account.RIQ_Health_Status__c ──▶ RIQ_Account_Critical_Alert (Flow)
                                   ├─▶ Custom Notification to the owner's manager
                                   └─▶ Chatter post on the account feed
```

### One code path

`RIQ_HealthScoreRecalculator.process(Set<Id>)` is the only place a score is
written. The Queueable (real-time), the nightly batch (time decay) and tests all
call it and get back a `ProcessResult` with counts and the list of real band
transitions. The Queueable is a three-line wrapper, so "the nightly number" and
"the number you see after logging a signal" cannot disagree.

### Events: what counts as a change

`RIQ_Health_Status_Change__e` is high-volume and published **after commit**, so a
rolled-back score never produces a task. It is published only when the band
changes.

**Decision: `null → status` publishes nothing.** A first score is a *baseline*,
not a transition. Otherwise the first nightly run after a data load would fire one
playbook per account and bury CSMs in executive-outreach tasks for customers
nobody has judged yet. The baseline is still recorded in `RIQ_Score_History__c`;
the automation starts at the first real move.

Every transition is published, not just the bad ones, because the event is a
domain statement ("the band moved"); deciding which transitions deserve work is
the subscriber's job. `RIQ_PlaybookService` subscribes to `At Risk` and
`Critical` only. `EventBus.publish` results are inspected and failures are counted,
so a dropped event shows up in the run summary instead of disappearing.

### What counts as a renewal Opportunity

A renewal is **`Opportunity.Type = 'Renewal'` and still open (`IsClosed = false`)**.
Nothing else suppresses the renewal motion, so an upsell in the pipeline cannot
accidentally hide a missing renewal, and last term's closed renewal cannot either.
The window is **contract end between today and today + 120 days, inclusive**.
Already-expired contracts are deliberately excluded: they belong to a
collections/win-back motion, not to a playbook whose value is the time left to act.
CloseDate is the contract end date and Amount is `RIQ_ARR__c`.

### Idempotency

Platform events are delivered **at least once**, so every playbook motion is
guarded twice:

1. the event batch is collapsed to one event per account in memory;
2. before creating anything, one SOQL loads all open `Executive outreach:` tasks
   and all open `Type = 'Renewal'` opportunities for the accounts in the batch.

A redelivered event therefore adds nothing. The guard is "is there already open
work for this account", not a message id, which also covers the case where a CSM
created that task by hand first.

### Why the trigger runs as a named user

By default a platform event trigger runs as **Automated Process**, so every Task
and Opportunity it creates shows `Created By: Automated Process` — an audit
dead end. `RIQ_HealthStatusChangeSubscriber` (a `PlatformEventSubscriberConfig`)
sets the running user to a real named user and the batch size to 200. In a
different org, change the `<user>` value to a username that exists there; it must
be an active user.

### Why this one piece is Flow

The Critical alert is deliberately **declarative**: "when status becomes Critical,
tell the owner's manager and post to the feed" is a notification policy, not
business logic. A Flow lets Customer Success ops change the recipients, title or
body, add a manager's manager, or turn it off, without a deployment or an Apex
test cycle. The manager lookup is a Decision element with a no-manager branch, and
both actions have **fault connectors**, so a missing manager, a missing
notification type, or Chatter being unavailable can never roll back the score
update. The feed post runs either way — only the bell notification needs a
manager. Everything with real logic — scoring, banding, event publishing,
idempotent task/opportunity creation — stays in Apex, where it is bulk-safe,
testable and reviewable.

## Flow vs Apex vs Platform Events vs Batch: when to use what

| Tool | Use it when | Not for | In RenewalIQ |
| ---- | ----------- | ------- | ------------ |
| **Record-triggered Flow** | The rule is simple, declarative, and an admin should be able to change it without a deployment: notifications, feed posts, field defaults, simple field updates. No loops over related records, no external callouts. | Bulk logic over related records, anything needing a test harness or a transaction boundary, anything that must be idempotent across retries. | `RIQ_Account_Critical_Alert` — bell notification to the manager + Chatter post. |
| **Apex trigger + handler** | Durable business rules on the same object, bulk data, cross-object logic that must be correct for 200 records at once, anything with tests and coverage. | Sending notifications nobody can tune; anything an admin will want to change weekly. | `RIQ_HealthSignalTrigger` (queue a recalculation), `RIQ_HealthStatusChangeTrigger` (run the playbook). |
| **Platform Event** | The producer should not know the consumers: one fact, many independent reactions, and the work must happen **after commit** so a rollback leaves no orphan task. Also the seam for external systems. | Request/response, ordered state changes, anything needing a guaranteed exactly-once semantic (events are at-least-once — design for idempotency). | `RIQ_Health_Status_Change__e` published by the scorer; consumed by the playbook. |
| **Batch Apex** | Whole-dataset work that must be chunked: nightly recalculation, data migration, anything that would blow synchronous limits. | A single record's immediate reaction — that is a trigger or a Queueable. | `RIQ_NightlyScoreBatch`, because scores decay with time even when nothing is edited. |
| **Queueable** | One transaction's follow-on work: move it off the user's request, keep a retry boundary, chain the next step. | Huge volumes (use Batch) or a fixed clock (use Schedulable + Batch). | `RIQ_HealthScoreRecalculator` — off-transaction re-score after a signal. |
| **Schedulable** | "Every night at 2 AM" — the clock itself. Keep it thin: it should only launch the batch. | Business logic (unbatchable, no scope, hard to test). | `RIQ_NightlyScoreScheduler.scheduleNightly()`. |

Rule of thumb: **Flow for policy, Apex for rules, events for decoupling, batch for
volume, Queueable for latency, Schedulable for the clock.**

## Data model

See [docs/DATA_MODEL.md](docs/DATA_MODEL.md) for fields, relationships, and the
scoring-rule contract.

## Roadmap

| Phase | Scope                                                    | Status |
| ----- | -------------------------------------------------------- | ------ |
| 1     | Project scaffold, data model, permission sets, seed data | ✅     |
| 2     | Health scoring engine + score history                    | ✅     |
| 3     | Nightly batch, platform events, playbook automation      | ✅     |
| 4     | LWC dashboard + Jest tests                               | ⬜     |
| 5     | AI summary callout, async + callout mocks                | ⬜     |

## Prerequisites

- Salesforce CLI (`sf`) — verify with `sf --version`
- Node.js + npm (for Prettier, ESLint and LWC Jest)
- Git
- A Developer Edition org or a Dev Hub for scratch orgs

## First-time setup

```bash
npm install
sf org login web --alias RenewalIQ --set-default
sf project deploy start --target-org RenewalIQ
sf org assign permset --name RIQ_Admin --target-org RenewalIQ   # metadata deploys do not grant profile FLS
sf apex run --file scripts/apex/seed-data.apex --target-org RenewalIQ
```

## Everyday commands

```bash
# Deploy only what changed
sf project deploy start --target-org RenewalIQ

# Run every Apex test with coverage
sf apex run test --target-org RenewalIQ --code-coverage --result-format human --wait 10

# Lint + format + LWC unit tests
npm run lint
npm run prettier
npm run test:unit
```

`npm run prettier` formats Apex and XML through `prettier-plugin-apex` and
`@prettier/plugin-xml`. The Apex plugin shells out to a bundled native
`apex-ast-serializer` binary; on machines where an application-control policy blocks
executables it fails with `blocked by your organization's Device Guard policy`, and
Apex formatting has to run on an unrestricted machine (CI works well for this).

## Project layout

```
force-app/main/default/
  applications/     RenewalIQ app
  classes/          Apex service, selector, handler, test classes
  customMetadata/   Scoring rules and status thresholds
  flexipages/       Lightning record pages
  flows/            RIQ_Account_Critical_Alert (record-triggered)
  lwc/              Dashboard + record components (with Jest tests)
  notificationtypes/  RIQ_HealthAlert custom notification type
  objects/          Account fields, signals, score history, platform event, batch config
  permissionsets/   RIQ_Admin, RIQ_CSM, RIQ_Read_Only
  platformEventSubscriberConfigs/  Named subscriber user for the event trigger
  tabs/             Custom object tabs
scripts/apex/       Anonymous Apex utilities (seeding, smoke tests)
docs/               Interview notes and data model reference
```

## Documentation

- [docs/DATA_MODEL.md](docs/DATA_MODEL.md) — objects, fields, scoring configuration
- [docs/INTERVIEW_NOTES.md](docs/INTERVIEW_NOTES.md) — design decisions per phase
