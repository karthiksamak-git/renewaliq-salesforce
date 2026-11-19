# RenewalIQ — Interview Q&A

Thirty questions I would expect about this project, answered the way I would answer them
out loud: specific, honest about the trade-offs, and including the bugs I actually hit.
The long-form design reasoning is in [INTERVIEW_NOTES.md](INTERVIEW_NOTES.md).

Numbers quoted here were measured on 19 November 2026 in the Developer Edition org
`00Dg800000A02p2EAB`: **198 Apex tests, 0 failing, 92% org-wide coverage**, and
**71 Jest tests** across four suites. Every account is synthetic demo data.

---

## Architecture and the scoring engine

**1. What is RenewalIQ, in one sentence?**
A Salesforce app that puts a customer's health score on the Account, explains it, and turns
a worsening account into an executive-outreach task and a renewal opportunity before the
renewal date arrives — instead of a CSM discovering the risk in a spreadsheet two weeks
before the contract ends.

**2. Why is the score a field on the Account instead of its own object?**
Every consumer already starts from the Account: list views, reports, the renewal
opportunity, the record page. A separate object would add a lookup to every query and make
a CSM open a second record to see one number. The Account is the aggregate root for customer
state, and health is customer state.

**3. Walk me through the score formula.**
`score = clamp(100 - Σ(weight × severity × decay), 0, 100)`, where
`decay = clamp(1 - daysSinceOccurred / decayDays, 0, 1)`. One formula handles penalties and
credits, because a credit like Positive Expansion is just a negative weight. The score is
banded by `RIQ_Threshold__mdt` (highest `Min_Score__c` first), and churn probability is
derived from the score plus a renewal-proximity bonus rather than configured separately.

**4. Why one formula instead of separate penalty and credit paths?**
Two paths always drift, and the classic bug is that the credit path forgets the clamp or
the decay. With signed weights the clamp, the decay and the driver list apply identically in
both directions, and there is one function to test.

**5. Why linear decay, and why is the window in Custom Metadata?**
Linear is something a CSM can reason about — "half weight at 45 of 90 days" — and needs one
number to configure. Putting `Decay_Days__c` on the rule means product can retune it without
a deployment.

**6. Why is the scoring engine a pure function with DTOs?**
`RIQ_HealthScoreService.calculate(...)` takes signals plus in-memory rules and returns a
result — no SOQL, no DML, no static state. Tests build their own rule sets, so they survive a
threshold change; and the trigger path, the nightly batch and tests all call the same code,
so a score cannot depend on where it was calculated.

**7. What is the hardest bulk-safety problem in the app?**
The trigger. A 200-row signal insert fires it once, but a CSM can also save several signals
in one transaction. The handler deduplicates Account ids into a `Set<Id>` and enqueues **one**
job, so the work is proportional to distinct customers, not to records. The 200-account test
asserts one history row per account — the assertion that fails first when someone adds SOQL
inside a loop.

**8. How do you keep the nightly number and the real-time number identical?**
There is one writer: `RIQ_HealthScoreRecalculator.process(Set<Id>)`. The Queueable is a
three-line wrapper around it; the batch calls it once per chunk. They cannot disagree, only
be stale.

## Data model and configuration

**9. Why Custom Metadata instead of Custom Settings or constants?**
CMDT is deployable, so the model travels with the code through sandboxes to production.
Custom Settings are data and drift per org. CMDT is also cached per transaction, so reading
all rules costs one cheap query, and admins edit it in Setup without a deployment.

**10. Why Master-Detail for signals but Lookup for history?**
A signal is owned by the customer: delete the Account and its evidence should go with it, and
the child inherits Account sharing. History is an audit trail I may want to retain and query
independently, so a lookup keeps the delete path simple.

**11. Why store the driver breakdown as JSON in a long text field?**
The set of contributing signals changes as rules are added; a column per signal would need a
schema change every time. JSON keeps the shape open. The score, status and churn are promoted
to real fields for reporting, so the loss is only field-by-field reporting of drivers.

**12. What happens if someone deactivates every scoring rule?**
Recalculation is skipped and logged, and the previous score is kept. Scoring with zero rules
subtracts nothing and would write 100 to every account — wiping a real book of business in one
nightly run. There is a test named for exactly that.

## Automation: Batch, events, playbook, Flow

**13. Signals already queue a recalculation — why a nightly batch too?**
Because the score decays with time. An account gets healthier with no DML at all, so without
the batch the score is only as fresh as the last human action — which is the stale-spreadsheet
problem the app exists to remove.

**14. Why publish a platform event instead of calling the playbook from the scorer?**
Coupling: every new consumer becomes an edit to the scorer, and a consumer failure rolls back
the score. The event inverts it, and it is publish-after-commit, so a rolled-back score can
never leave an orphan task.

**15. Platform events are at-least-once. How is the playbook idempotent?**
Twice over. In memory, the batch collapses to one event per account; against the org, one SOQL
loads all open `Executive outreach:` tasks and all open `Type = 'Renewal'` opportunities before
anything is created. The guard is "is there already open work for this account", not a message
id — so it also protects against a CSM having created that task by hand.

**16. What counts as a renewal opportunity, and why so narrow?**
`Type = 'Renewal'` **and** `IsClosed = false`, with the contract ending between today and
today + 120 days. If any open opportunity counted, a genuine expansion would hide a missing
renewal; if any renewal counted, last term's closed deal would suppress this term's — the
account would silently never get a renewal.

**17. Why does the Flow exist when everything else is Apex?**
Because it is policy, not logic: "when the band becomes Critical, tell the owner's manager and
post to the feed" is something Customer Success ops should change without a deployment. The
Flow has a no-manager branch and fault connectors on both actions, so a missing manager or
Chatter being unavailable can never roll back the score update.

**18. What is the `null → status` decision?**
A first score is a baseline, not a transition, so it publishes no event. Otherwise the first
nightly run against a newly loaded book would fire one playbook per account and bury CSMs in
outreach tasks for customers nobody has judged yet. The baseline is still audited in history.

## Lightning Web Components

**19. How does the UI stay honest about asynchronous scoring?**
Logging a signal shows "Score updating…", waits a bounded 4 seconds, then publishes on the
`RIQ_Score_Refresh__c` message channel; the card calls `refreshApex` on its wired result.
Showing an instant new score would be inventing a number.

**20. That bounded timer is a smell. What would you do instead?**
Publish the refresh from the Queueable at the end of `execute()`, so the card updates when the
score actually changed rather than when the timer expired. It is in the known limitations of
the README because it is the weakest part of the UI design.

**21. Why are the aggregates in SOQL rather than Apex loops?**
Every KPI is a `COUNT()`, `SUM()`, `AVG()` or one `GROUP BY RIQ_Health_Status__c`; the
drill-down is one flat query. Loading 10,000 accounts to sum them in Apex burns heap for a
number the database computes in one pass, and makes governor cost grow with the book.

**22. What do the Jest tests prove, and what do they not?**
They prove behaviour: filters reaching Apex with the right arguments, datatable sort mapping,
validation blocking submission before any call, the "updating" state and its later message,
empApi subscribe/unsubscribe, the Chart.js fallback donut, and now the sparkline caption and
per-point tooltips — 71 tests. They do not prove it _looks_ right: Jest renders a shadow DOM,
not a page. Gauge proportions and wrapping still need a human in a browser.

**23. Why Chart.js from a static resource?**
A CDN is a runtime dependency on someone else's uptime and may be blocked by CSP or network
policy. If `loadScript` fails or the global is hidden by Lightning Web Security, the component
renders a pure-SVG donut built from the same segments, and a Jest test forces that path.

## Integrations

**24. Where does the LLM key live, and how do you prove it is not in the repository?**
Nowhere in the repository. The External Credential declares a principal and an authentication
parameter _named_ `apiKey` with no value; the value is entered once in Setup and lives in the
org's protected store. The Named Credential is a secured endpoint, so Apex only sees
`callout:RIQ_LLM_API/...`. The proof is negative and repeatable: a grep for key-shaped strings
across the working tree and the full git history finds nothing, and the suite uses
`HttpCalloutMock`, so it never touches the network.

**25. What happens when the model fails?**
Everything lands in the same place: a deterministic rule-based summary stored with
`RIQ_AI_Source__c = 'Rule-based'` and shown with a **Rule based** badge. Timeout, 429 (where
`Retry-After` is logged but never waited on), 5xx, 400/401, empty or malformed content, and an
answer wrapped in code fences are all treated as hostile input and repaired or replaced. A
user never sees an HTTP status, and a fallback can never be mistaken for a model answer.

**26. Why is the inbound API a separate concern from the UI?**
Because it writes through the same trigger. `POST /services/apexrest/riq/v1/signals` upserts up
to 200 signals with `externalId` as the idempotency key, returns per-row results
(`created`/`updated`/`skipped`/`error`) with HTTP 200 on partial success, and reserves 400/413
for unreadable or oversized bodies. There is no second write path, so a signal from an external
tool scores exactly like one typed into the form.

## Security

**27. Why check a Custom Permission in Apex instead of hiding the button?**
Hiding a button is UX, not a control — anyone can call the method through the API, a Flow or a
hand-written component. `RIQ_Read_Only` has neither `RIQ_Recalculate_Health` nor
`RIQ_Log_Health_Signals`, and the test suite calls the methods directly as that user, which is
what an attacker would do.

**28. Why does the scorer use `SYSTEM_MODE` if `USER_MODE` is the default?**
The score fields are read-only for CSMs, so writing them under the triggering user's
permissions would fail for exactly the person most likely to log a signal. The Account ids come
from records that user just touched, so it is not an escalation — and it is written as
`AccessLevel.SYSTEM_MODE` at the call site rather than hidden behind `without sharing`.

## Delivery, CI and the bugs that taught me something

**29. Tell me about a bug that only appeared in CI.**
Two, in the same job. The Apex job crashed at "Install the Code Analyzer plugin" with
`TypeError: webidl.util.markAsUncloneable is not a function` — the Salesforce CLI no longer
supports Node 18 or 20, so the job had to move to Node 24. Then the next run failed at "this
schedulable class has jobs pending": the long-lived Developer org has scheduled jobs, and Abort
→ deploy → Re-schedule is a real operational step, documented in the README and in
`scripts/apex/`. Neither was visible locally, which is the point of running the pipeline.

**30. And a bug that was not code at all?**
The CI secret. I generated `SFDX_AUTH_URL` with `sf org display --json`, and the CLI returned the
literal string `[REDACTED] Use 'sf org auth show-access-token'` where the URL should be. The
secret looked set — 55 characters, plausible length — and every run failed with an auth error
that pointed at the deploy rather than the secret. The fix was to use
`sf org auth show-sfdx-auth-url` and to make the generator fail loudly when the value is short
or masked. Lessons: a secret that looks plausible is worse than a missing one, and a pipeline
error message names the step, not the cause.

**31. What other real bugs did the project hit?**
Four worth naming. **Scratch-org portability**: `PlatformEventSubscriberConfig` names a user, and
a username only exists in one org — it is now a `.template` rendered by the setup scripts, and the
app works without it (Tasks just show `Created By: Automated Process`). **A retired Groq model**:
the configured model was withdrawn by the provider and every call returned an error, which is why
the model name is a Custom Metadata field rather than a constant. **A time-zone test flake**: the
playbook test compared `Date.today()` in the test with "today" in an event trigger running as
another user; it passed in the Developer org and failed in a scratch org, so the due-date assertion
now allows one day and the 120-day boundary is asserted against the service's own predicate in one
context. **CRLF line endings**: Git on Windows checked out `\r\n`, Prettier and the Apex parser
disagreed, and the fix was `.gitattributes` plus formatting in CI on Linux.

**32. What would you improve next?**
Four things, in order: publish the score refresh from the Queueable instead of a 4-second timer;
test the sharing model with two CSMs holding separate books, which a two-licence Developer
Edition cannot do properly; replace the full-deploy workflow with delta deployments so the AI
toggle is not reset by unrelated changes; and add a two-client end-to-end test of the inbound API
with a real integration user rather than Apex-only coverage.
