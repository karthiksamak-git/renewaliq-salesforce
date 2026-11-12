# RenewalIQ — Data Model

All custom API names are prefixed `RIQ_`. There is no managed-package namespace, so
`RIQ_` is a naming convention enforced by review and by the metadata in this repo.

## Account (standard object, extended)

Customer health lives on the Account record itself so it can be reported, filtered,
and used in list views and flows without a lookup.

| Field                      | Type                  | Purpose                                                                              |
| -------------------------- | --------------------- | ------------------------------------------------------------------------------------ |
| `RIQ_Health_Score__c`      | Number(3,0)           | 0–100 health score. Written by the scoring engine, never by hand.                    |
| `RIQ_Health_Status__c`     | Picklist              | Banded status: Healthy, Watch, At Risk, Critical. Derived from `RIQ_Threshold__mdt`. |
| `RIQ_Churn_Probability__c` | Percent(3,0)          | Model output 0–100 %, shown as a % on the record.                                    |
| `RIQ_Last_Scored__c`       | DateTime              | When the engine last recalculated this Account. Drives "stale score" reporting.      |
| `RIQ_AI_Summary__c`        | Long Text Area(32768) | LLM-written narrative of account state.                                              |
| `RIQ_Next_Best_Action__c`  | Text(255)             | LLM-recommended single next action for the CSM.                                      |
| `RIQ_Contract_End_Date__c` | Date                  | Renewal anchor; drives the renewal window and Opportunity creation.                  |
| `RIQ_ARR__c`               | Currency(18,2)        | Annual recurring revenue — the weighting input for prioritisation.                   |

`RIQ_Health_Score__c`, `RIQ_Health_Status__c`, `RIQ_Churn_Probability__c` and
`RIQ_Last_Scored__c` have field history tracking on so score movement is auditable.

## RIQ_Health_Signal__c (child of Account, Master-Detail)

The raw evidence behind a score. A master-detail relationship is used because a
signal has no meaning without its customer: it should cascade-delete with the
Account, inherit Account sharing, and roll up cleanly.

| Field                | Type                       | Notes                                                                                                                                     |
| -------------------- | -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `Name`               | AutoNumber `RIQ-HS-{0000}` | Human-readable signal reference.                                                                                                          |
| `Account__c`         | Master-Detail(Account)     | Required; relationship name `Health_Signals`.                                                                                             |
| `Signal_Type__c`     | Picklist                   | Support Escalation, Low Product Usage, Missed QBR, Executive Sponsor Left, Late Payment, NPS Detractor, Positive Expansion. **Required.** |
| `Severity__c`        | Number(1,0)                | 1–5, where 5 is most severe.                                                                                                              |
| `Occurred_On__c`     | Date                       | **Required.** Drives time decay in scoring.                                                                                               |
| `Notes__c`           | Long Text Area(1000)       | Free-text context from the CSM or integration.                                                                                            |
| `Weight_Override__c` | Number(6,2)                | Optional per-signal weight that beats the metadata default.                                                                               |

## RIQ_Score_History__c (child of Account, Lookup)

An append-only audit trail of every recalculation. A lookup (not master-detail) is
used so history survives independently and can be queried without cascading
deletes blocking Account cleanup.

| Field              | Type                       | Notes                                                    |
| ------------------ | -------------------------- | -------------------------------------------------------- |
| `Name`             | AutoNumber `RIQ-SH-{0000}` | History reference.                                       |
| `Account__c`       | Lookup(Account)            | Clears to null if the Account is deleted.                |
| `Score__c`         | Number(3,0)                | Score at the moment of calculation.                      |
| `Status__c`        | Picklist                   | Banded status at that moment (same 4 values as Account). |
| `Calculated_On__c` | DateTime                   | Calculation timestamp — the chart's x-axis.              |
| `Drivers__c`       | Long Text Area(32768)      | JSON breakdown of which signals contributed what.        |

## RIQ_Scoring_Rule__mdt (configuration)

One record per signal type. The scoring engine reads these; no weight or decay
window is hardcoded in Apex.

| Field            | Type        | Notes                                                                                  |
| ---------------- | ----------- | -------------------------------------------------------------------------------------- |
| `Signal_Type__c` | Picklist    | Matches `RIQ_Health_Signal__c.Signal_Type__c`.                                         |
| `Base_Weight__c` | Number(6,2) | Points subtracted from 100. **Negative values are credits** (e.g. Positive Expansion). |
| `Decay_Days__c`  | Number(6,0) | Window over which a signal's impact fades to zero.                                     |
| `Is_Active__c`   | Checkbox    | Kill switch per rule without deleting history.                                         |

Seeded records: Support Escalation (25 / 90 days), Low Product Usage (15 / 60),
Missed QBR (10 / 120), Executive Sponsor Left (20 / 180), Late Payment (12 / 90),
NPS Detractor (8 / 45), Positive Expansion (−15 / 60).

## RIQ_Threshold__mdt (configuration)

Maps a score to a status band, highest band first.

| Record   | `Status__c` | `Min_Score__c` |
| -------- | ----------- | -------------- |
| Healthy  | Healthy     | 80             |
| Watch    | Watch       | 60             |
| At_Risk  | At Risk     | 40             |
| Critical | Critical    | 0              |

The engine evaluates bands in descending `Min_Score__c` order and takes the first
match, so exactly one band can ever apply and a score of 0 still resolves.

## Access

| Permission set  | Intent                                                                                |
| --------------- | ------------------------------------------------------------------------------------- |
| `RIQ_Admin`     | Full create/read/edit/delete on all RIQ objects and fields, plus tab visibility.      |
| `RIQ_CSM`       | Read/edit on Accounts and signals, read/create on score history — the daily CSM user. |
| `RIQ_Read_Only` | Reporting/executive access: read everything, change nothing.                          |
