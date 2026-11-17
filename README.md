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
| UI               | LWC command center + record components            | `riqCommandCenter`, `riqHealthScoreCard`, `riqSignalLogger` |

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

## The Lightning layer (Phase 4)

```
riqCommandCenter   (App Page)      KPIs · status donut · at-risk datatable · row action
riqHealthScoreCard (Account page)  gauge · badge · churn · top-3 drivers · 12-point trend
riqSignalLogger    (Account page)  validated form → Apex → "score updating…" → refresh
riqUtils           (utility module) pure formatting + SVG geometry, unit tested directly
```

Two Apex controllers sit behind them, and all three components go through them rather
than through their own SOQL:

| Method | Cacheable | Why |
| ------ | --------- | --- |
| `RIQ_DashboardController.getKpis(ownerId, renewalWindowDays)` | yes | Pure read; the tile totals. |
| `RIQ_DashboardController.getStatusDistribution(ownerId)` | yes | Pure read; one `GROUP BY` count, one row per band. |
| `RIQ_DashboardController.getAtRiskAccounts(filters)` | yes | Pure read; server-side filter, sort and row cap. |
| `RIQ_AccountHealthController.getHealthCard(accountId)` | yes | Pure read; wired on the record page. |
| `RIQ_AccountHealthController.recalculate(accountId)` | **no** | It writes scores, history and possibly an event. |
| `RIQ_AccountHealthController.logSignal(...)` | **no** | It inserts a signal. |

### Aggregation belongs in the database

Every number on the dashboard is a SOQL aggregate (`COUNT()`, `SUM()`, `AVG()`,
`GROUP BY RIQ_Health_Status__c`) or a single flat query — never a query that loads 10,000
accounts so Apex can add them up. That keeps the governor cost independent of the size of
the book, and it means the KPI tile and the drill-down table are computed by the same
engine that stores the data.

### What the browser is allowed to decide

The sort field is whitelisted in Apex (`SORT_FIELDS` map), the row count and renewal
window are clamped server-side (50/200 rows, 730 days), and the status filter treats
`All` as "At Risk + Critical" rather than "everything". Nothing from the client becomes
a `Database.query` string.

### Permissions are enforced twice

`Recalculate` and `Log signal` are guarded by **Custom Permissions**
(`RIQ_Recalculate_Health`, `RIQ_Log_Health_Signals`) checked with
`FeatureManagement.checkPermission` inside the controller. `RIQ_Read_Only` therefore gets
a friendly `AuraHandledException` if it calls the method directly — hiding a button in the
component is a convenience for the user, never the control.

### Charts without a CDN

Chart.js 4.6.1 is a `devDependency`, and its UMD build is copied into the `chartjs`
static resource and loaded with `loadScript`. Under Lightning Web Security the global can
be hidden from the component, so if `loadScript` fails or `window.Chart` is missing the
component renders a **pure SVG donut** built from the same segments by `riqUtils`. There
is no blank panel and no third-party request at runtime.

### Honest async

Logging a signal queues a `Queueable`, so the score cannot be new the instant the form
submits. `riqSignalLogger` says so: it shows a "Score updating…" state, then publishes on
the `RIQ_Score_Refresh__c` Lightning Message channel; `riqHealthScoreCard` listens and
calls `refreshApex` on its wired result. A score that silently changed would be worse than
one that is visibly a few seconds behind.

`riqCommandCenter` also subscribes to `/event/RIQ_Health_Status_Change__e` with empApi, so
a band change from anyone's action toasts in and refreshes the tiles — and
`disconnectedCallback` unsubscribes, because a leaked empApi subscription keeps firing
against a destroyed component.

### Testing the UI

53 Jest tests: the pure helpers directly (donut geometry, sparkline scaling, gauge arc,
currency/percent/days formatting), and each component through its rendered shadow DOM —
loading, empty and error states, filter changes reaching Apex with the right arguments,
datatable sort mapping, the row action, toasts, validation blocking submission, the
"score updating" state, empApi subscribe/unsubscribe, the Chart.js fallback, and the
insight panel (stored summary, empty state, generate, refusal, permission-hidden button).

## The integration layer (Phase 5)

RenewalIQ integrates in two directions, and both are optional: with no API key and
no inbound caller, every screen still works.

**Outbound — a written insight per account.** `RIQ_AiInsightService` builds a
deterministic prompt from the score, the status, the top five drivers, the ten most
recent signals, ARR and the contract end date, and asks a language model for a
summary, a next best action and up to three risk reasons as JSON. The provider is
**Groq** (`https://api.groq.com`, `/openai/v1/chat/completions`, OpenAI-compatible),
reached through a **Named Credential** (`RIQ_LLM_API`) over an **External Credential**
whose custom `Authorization: Bearer …` header is filled from the org's protected
credential store, so no key exists in code, metadata, tests, documentation or git. An
`RIQ_AI_Config__mdt` record decides whether the callout happens at all — it ships
**disabled**, so the project is reproducible without anyone's key — and holds the
provider, request path, model name, token cap and timeout, which means switching model
or provider is an admin edit, not a deployment.

The request is an OpenAI-style chat completion (system instruction, user message,
`temperature: 0.2`, JSON mode) and the answer is treated as hostile input: code
fences are stripped, `choices[0].message.content` is read, missing fields are repaired
and lengths are capped. Timeout, 429 (where `Retry-After` is logged but never waited
on), 5xx, 400/401, empty or malformed content all land in the same place — a **rule-based insight** built from the score, drivers and signals, stored
with `RIQ_AI_Source__c = 'Rule-based'` and shown with a **Rule based** badge instead
of **AI generated**. The user never sees a raw error or an HTTP status, and a
fallback can never be mistaken for a model answer.

No callout runs inside a trigger, a batch, or after uncommitted DML. The record-page
button calls the service first and then performs one update; the playbook path
enqueues `RIQ_AiInsightQueueable`, which processes three accounts per job and chains
the rest, so a 200-account run becomes short jobs instead of one that dies at the
async limit.

**Inbound — `POST /services/apexrest/riq/v1/signals`.** Up to 200 signals per
request, with `externalId` as the idempotency key upserted onto a unique external-id
field, so a retry updates instead of duplicating. Partial success is HTTP 200 with a
per-row result array (`created` / `updated` / `skipped` / `error`); 400 is reserved
for a body that cannot be read, 413 for more than 200 items. The resource is
`with sharing` and runs in `USER_MODE` end to end, with a dedicated
`RIQ_Integration_User` permission set as the caller's ceiling. Writing a signal
through the API fires the same trigger path as logging one in the UI — there is no
second write path.

Details, including the exact setup steps for the credential, the provider switch and
the curl/authentication walkthrough, are in [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md)
and [docs/API.md](docs/API.md).

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
| 4     | LWC dashboard + Jest tests                               | ✅     |
| 5     | LLM callout (Named/External Credential), inbound signal REST API | ✅     |
| 6     | Security review: sharing, CRUD/FLS, injection, secret handling | ⬜     |

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
  customMetadata/   Scoring rules, status thresholds, RIQ AI Config (model, tokens, timeout, toggle)
  externalCredentials/  RIQ_LLM_API principal with the Authorization bearer header (value never committed)
  flexipages/       Lightning record pages
  flows/            RIQ_Account_Critical_Alert (record-triggered)
  lwc/              Command center, score card, signal logger, shared helpers (+ Jest)
  messageChannels/  RIQ_Score_Refresh (Lightning Message Service)
  notificationtypes/  RIQ_HealthAlert custom notification type
  namedCredentials/ RIQ_LLM_API SecuredEndpoint pointing at the provider base URL
  objects/          Account fields, signals, score history, platform event, batch config, AI config CMDT
  permissionsets/   RIQ_Admin, RIQ_CSM, RIQ_Read_Only, RIQ_AI_Insight, RIQ_Integration_User
  platformEventSubscriberConfigs/  Named subscriber user for the event trigger
  staticresources/  chartjs (Chart.js 4.6.1 UMD build, served from the org)
  tabs/             Custom object tabs + the Command Center tab
scripts/apex/       Anonymous Apex utilities (seeding, smoke tests, live callout check)
docs/               Interview notes and data model reference
```

## Documentation

- [docs/DATA_MODEL.md](docs/DATA_MODEL.md) — objects, fields, scoring configuration
- [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md) — LLM callout setup (credential, toggle, provider switch, troubleshooting)
- [docs/API.md](docs/API.md) — inbound signal API: auth, payload, responses, idempotency, security
- [docs/INTERVIEW_NOTES.md](docs/INTERVIEW_NOTES.md) — design decisions per phase
- [docs/SCREENSHOTS.md](docs/SCREENSHOTS.md) — screenshot checklist for the portfolio write-up
