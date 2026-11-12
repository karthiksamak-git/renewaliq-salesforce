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
| Config           | Thresholds and weights, no hardcoded numbers      | `RIQ_Scoring_Rule__mdt`, `RIQ_Threshold__mdt` |
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

## Data model

See [docs/DATA_MODEL.md](docs/DATA_MODEL.md) for fields, relationships, and the
scoring-rule contract.

## Roadmap

| Phase | Scope                                                    | Status |
| ----- | -------------------------------------------------------- | ------ |
| 1     | Project scaffold, data model, permission sets, seed data | ✅     |
| 2     | Health scoring engine + score history                    | ✅     |
| 3     | Renewal automation (Opportunities, playbook Tasks)       | ⬜     |
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
  lwc/              Dashboard + record components (with Jest tests)
  objects/          Account fields, RIQ_Health_Signal__c, RIQ_Score_History__c
  permissionsets/   RIQ_Admin, RIQ_CSM, RIQ_Read_Only
  tabs/             Custom object tabs
scripts/apex/       Anonymous Apex utilities (seeding, smoke tests)
docs/               Interview notes and data model reference
```

## Documentation

- [docs/DATA_MODEL.md](docs/DATA_MODEL.md) — objects, fields, scoring configuration
- [docs/INTERVIEW_NOTES.md](docs/INTERVIEW_NOTES.md) — design decisions per phase
