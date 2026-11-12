# RenewalIQ — Interview Notes

Design decisions per phase, written in the voice of an interview answer: what the
problem was, what I chose, and what I traded away.

---

## Phase 1 — Scaffold & Data Model

**1. Why put the health score on the Account instead of a custom "Customer Health"
object?**
Because every consumer — list views, reports, the dashboard, renewal flows — already
starts from the Account. A separate object would add a lookup to every query and
force CSMs to open a second record to see the number. The Account is the natural
aggregate root for customer state, and the score is customer state.

**2. Why Master-Detail for `RIQ_Health_Signal__c` but Lookup for `RIQ_Score_History__c`?**
A signal is _owned_ by the customer — delete the Account and its evidence should go
with it, and the child should inherit Account sharing. History is different: it is
an audit trail I may want to retain or query independently, and a lookup keeps the
delete path simple. Master-detail also caps a child at two per object, which
influences later modelling.

**3. Why Custom Metadata Types for rules and thresholds instead of Custom Settings
or hardcoded constants?**
CMDT is deployable — the model travels with the code through sandboxes to
production. Custom Settings are data, not metadata, so a threshold change would be
made by hand in each org and could drift. CMDT records are also cached in the
platform cache layer per transaction, so reading all rules costs one cheap query,
and they are editable by admins without a deployment.

**4. Why is `Base_Weight__c` signed, with a negative weight for Positive Expansion?**
It makes "a rule can only hurt you" false by construction: the scoring engine sums
weights uniformly and subtracts the total from 100, so a credit is just a negative
weight. That avoids a second code path for positive signals and keeps the rule
table expressive.

**5. Why does `RIQ_Score_History__c.Drivers__c` store JSON in a long text field?**
The set of contributing signals changes as CMDT rules are added, so a column per
signal would need a schema change every time a rule is introduced. JSON keeps the
shape open. The trade-off is that it is not reportable field-by-field — which is
acceptable because the score itself and the status are promoted to real fields for
reporting, and Drivers exists for explainability in the UI.

**6. Why permission sets and not profiles?**
Profiles are one-per-user and cannot be composed; CSM plus Admin would require
either a clone or a profile change. Permission sets layer, so the same user can
hold `RIQ_CSM` and an admin grant, and the access intent is visible in source
control as metadata.

---

## Phase 2 — Apex Architecture & Health Scoring Engine

**1. Why a trigger handler framework instead of logic in the trigger?**
A trigger body cannot be called from a test or a script, and it cannot be reused by
a future batch job that needs the same behaviour. Moving it into a virtual handler
means the same code path runs for UI DML, Data Loader and Apex, and the trigger
file stays three lines long. The base class also gives every handler the same
bypass switch and recursion guard instead of each handler inventing its own.

**2. Why does the handler enqueue a queueable instead of scoring synchronously?**
Scoring needs one query for accounts, one for signals and two DML statements. Doing
that inside an after-insert trigger spends the user's synchronous transaction budget
on work the user is not waiting for, and it re-enters if the engine ever updates the
object that fired the trigger. A queueable moves that cost out of the request and
gives me a natural retry boundary.

**3. Why deduplicate Account ids before enqueuing, and why only one job?**
A 200-row signal insert fires the trigger once, but a user can also save several
signals in one transaction. Enqueuing per signal would hit the 50-job queueable limit
and recalculate the same account repeatedly. The handler collects a `Set<Id>`, so
the work is proportional to the number of distinct customers, not the number of
records. That is what makes the bulk test meaningful.

**4. Why is the scoring engine a pure function with its own DTOs?**
`RIQ_HealthScoreService` takes signals plus in-memory rules and returns a result — no
SOQL, no DML, no static state. That means the formula can be unit tested against
hand-built rule sets rather than whatever happens to be deployed in the org, so the
tests survive a threshold change. It also means the LWC preview, the trigger and a
future nightly batch call the identical code, so a score can never differ depending
on where it was calculated.

**5. Why does the trigger path use SYSTEM_MODE when the selectors default to USER_MODE?**
`USER_MODE` is the default because a user-facing query should never bypass sharing or
FLS. The scoring engine is the documented exception: `RIQ_Health_Score__c` and
`RIQ_Health_Status__c` are read-only for `RIQ_CSM`, so writing them under the
triggering user's permissions would fail for exactly the person most likely to log a
signal. The ids passed in come from records that user already touched, so this is not
an escalation — and the exception is visible in the code as `AccessLevel.SYSTEM_MODE`
rather than hidden behind a `without sharing` default.

**6. Why one formula with signed weights instead of separate penalty and credit logic?**
`score = 100 - Σ(baseWeight × severity × decayFactor)` treats a credit as a negative
penalty. Two code paths would eventually disagree — the classic bug is a positive
signal that bypasses clamping or decay. One formula means the clamp, the decay and
the driver list apply identically in both directions.

**7. Why linear decay, and why is the decay window in Custom Metadata?**
A support escalation from three months ago should not hurt as much as one from
yesterday, so each rule carries its own `Decay_Days__c`. Linear decay is chosen over
exponential because a CSM can reason about it ("half weight at 45 of 90 days") and
because it needs no configuration beyond one number. Product can retune it without a
deployment.

**8. Why is churn probability derived rather than configured?**
Churn depends on two different things: how unhealthy the account is, and how close the
renewal is. Storing it as a second set of thresholds would let the two disagree with
the score. Instead it is computed from the score plus a renewal-proximity bonus, so it
moves automatically when either input changes, and it stays a single testable function.

**9. Why are only the top three drivers surfaced but every contribution stored as JSON?**
The UI needs a short "why" — three reasons is the most a CSM will read. The audit
record needs the complete picture, because "why did my score drop 12 points" must be
answerable months later. Storing JSON keeps the payload schema-free as rules are added,
while the score, status and churn stay as real fields for reporting.

**10. How is this bulk safe, and what did the tests prove?**
One query per object per transaction, rule and threshold lookups cached in static
fields, and DML issued once for the whole account list. `RIQ_HealthSignalTrigger_Test`
inserts 200 signals across 200 accounts and asserts every account is scored with
exactly one history row each — the case that fails first when someone adds SOQL inside
a loop.
