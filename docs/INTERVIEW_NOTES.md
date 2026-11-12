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
