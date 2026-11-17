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

---

## Phase 3 — Automation: Batch, Platform Events, Playbook, Flow

**1. Why refactor the Queueable into a shared `process()` instead of copying the logic into the batch?**
Because two implementations of "how a score is calculated and stored" will drift, and the drift is invisible until a CSM asks why the dashboard disagrees with last night's job. `process(Set<Id>)` is now the only writer of score fields; the Queueable is a three-line wrapper and the batch calls the same method per chunk. The refactor also gave the callers something they did not have before: a result object with processed/updated/history/status-change/failure counts, which is exactly what a batch needs to report a run and what a test needs to assert.

**2. Signals already queue a recalculation — why a nightly batch as well?**
Because the score is time-decayed. A signal ages out on its own schedule, so an account can get healthier without anyone editing anything: no DML, no trigger, no Queueable. The batch is the clock of the model. Without it the score is only as fresh as the last human action, which is precisely the stale-spreadsheet problem the project exists to remove.

**3. Why does the batch call `process()` directly instead of enqueueing a Queueable per chunk?**
A batch chunk is already an async transaction with its own governor limits, so the Queueable would add nothing but a serialized boundary. Worse, enqueueing from inside a batch burns the 50-job queueable limit and makes the job's own stateful counters meaningless, because the work would finish after `finish()` ran. One call per chunk keeps the counters honest.

**4. Why publish a platform event instead of calling the playbook directly from the scorer?**
Direct coupling would mean the scoring transaction owns task creation, renewal creation and every future reaction to a band change. Every new consumer becomes another edit to the scorer, and any failure in a consumer rolls back the score. The event inverts that: the scorer publishes one fact ("Health band moved from X to Y"), and consumers subscribe. It is also `PublishAfterCommit`, so a rolled-back score can never leave an orphan Task behind — the exact bug a synchronous fan-out would create.

**5. Why publish every transition if the playbook only cares about At Risk and Critical?**
The event is a domain statement, not a command. Publishing only the "interesting" transitions would bake today's automation policy into the producer, and the next consumer (a manager digest, an external CRM sync) would have to change the scorer. Filtering belongs in the subscriber. It also means a Healthy→Watch move is observable in event logs while creating no work.

**6. What did you decide about `null → status`, and why?**
A first score is a baseline, not a transition, so it publishes nothing. If it did, the first nightly run against a newly loaded book of accounts would fire one playbook per account — hundreds of "Executive outreach" tasks for customers nobody has judged yet, which is the fastest way to teach a CSM to ignore the feature. The baseline is still audited in `RIQ_Score_History__c`; automation begins at the first real move. This is a documented product decision, not an accident of `!=`.

**7. Platform events are at-least-once. How is the playbook idempotent?**
Two layers. In memory, the batch is collapsed to the newest event per account, so five transitions in one delivery produce one task. Against the org, one SOQL loads all open `Executive outreach:` tasks and all open `Type = 'Renewal'` opportunities for the accounts in the batch before anything is created. The guard is "is there already open work", not a message id — so it also protects against a CSM having created that task by hand. Nothing is written per event, so 200 events cost one query per object and one insert per object.

**8. Why a `PlatformEventSubscriberConfig` with a named user?**
Without it, every record the trigger creates is owned and created by **Automated Process**, an audit dead end: the Task on a $200k renewal says nobody created it. The config sets the running user to a real named user, so `Created By` is meaningful and the records have a stable owner context. It also lets us set the batch size (200 here). The trade-off is that the username is org-specific, so the metadata file has to be pointed at a user that exists in the target org.

**9. Why is the Critical alert a Flow when everything else is Apex?**
Because it is policy, not logic: "when the band becomes Critical, tell the owner's manager and post to the feed." Customer Success ops will want to change the wording, add the manager's manager, or switch it off, and none of that should require a deployment and a test cycle. A record-triggered Flow with a Decision element and fault connectors expresses it in a screen an admin can read. The logic that must be correct for 200 records at once — scoring, banding, idempotent creation — stays in Apex where it has coverage and a bulk test. The split is "declarative for notification policy, Apex for business rules".

**10. Why does the Flow need fault connectors and a no-manager branch?**
Because a notification is a side effect, and side effects must never roll back the business fact. No manager on the owner skips only the bell notification and still posts to the feed; a failed notification falls through to the feed post; a failed feed post ends the flow quietly. None of those throws, so the score update still commits. The Apex test asserts both halves: a Critical transition commits even when the Flow cannot notify, and the feed post is still created when there is no manager.

**11. Why Custom Metadata for the batch size instead of a Custom Setting or a constant?**
A constant needs a deployment to tune, and batch size is an operational knob (nightly load, org limits) that ops should own. Custom Metadata is deployable configuration — it travels with the code through sandboxes, unlike Custom Settings which are data and drift per org. It is also cacheable and readable in tests, and the code still falls back to 200 if the record is missing, so a missing config can never stop the job.

**12. Why is a "renewal Opportunity" defined as Type = 'Renewal' and open?**
Because the suppression rule needs to be precise. If any open opportunity counted, a genuine expansion deal would hide a missing renewal. If any `Type = 'Renewal'` counted, last term's closed renewal would suppress this term's — the worst possible outcome, since the account would silently never get a renewal. `Type = 'Renewal' AND IsClosed = false` is the narrowest rule that means "this term's renewal is already being worked".

**13. How do you know 200 events are safe?**
`RIQ_PlaybookService_Test.twoHundredEventsAreHandledInBulk` publishes 200 events, delivers them, and asserts 200 tasks and 200 opportunities. The service issues one Account query, one Task query, one Opportunity query and two inserts for the whole batch — no SOQL or DML inside a loop, which is the failure mode the test is designed to catch. The nightly batch is tested the same way with 201 accounts across two chunks, and asserts the stateful counters as well as the data.

---

## Phase 4 — Lightning Web Components

**1. Why three components and a shared module instead of one dashboard component?**
Because they have three different lifetimes. The command center is a page, the score card lives on the Account record page, and the signal logger is a form that writes data — putting them in one bundle would mean one bundle's worth of tests, one `@api recordId` that is meaningless on a page, and no way to place the card and the form in different regions of a record page. The shared pieces are exactly the things with no DOM: donut geometry, sparkline scaling, gauge arcs, currency/percent/day formatting. That module is a pure function library, which is why its tests are plain assertions instead of rendered components.

**2. Why do the aggregates in SOQL rather than looping in Apex?**
Every KPI on the command center is a `COUNT()`, `SUM()`, `AVG()` or a single `GROUP BY RIQ_Health_Status__c`, and the drill-down is one flat query. Loading 10,000 accounts into Apex to sum them would burn heap for a number the database computes in one pass, and it would make the dashboard's governor cost grow with the book of business. The query cost is now flat: one aggregate per tile, one grouped query for the donut, one query for the table.

**3. When is `cacheable=true` correct, and when is it a bug?**
Only when the method is a pure read of data the caller is allowed to see, with no side effects and nothing time-sensitive. `getKpis`, `getStatusDistribution`, `getAtRiskAccounts` and `getHealthCard` qualify. `recalculate` and `logSignal` do not, and marking them cacheable would be a correctness bug, not a performance win: the platform caches the response, so the second CSM to press the button would get a stale card and no recalculation would happen. The safest habit is that a method which writes is never cacheable, no matter how cheap it is.

**4. How do you keep the dashboard and the record page agreeing on the same number?**
Both read the fields the scorer writes (`RIQ_Health_Score__c`, `RIQ_Health_Status__c`, `RIQ_Churn_Probability__c`) — neither computes a score. So they cannot disagree, they can only be stale. Staleness is handled explicitly: the card is wired and cacheable, so after a mutation it calls `refreshApex` on the wired result rather than trusting the cache.

**5. Why Custom Permissions checked in Apex instead of just hiding the buttons?**
Hiding a button is a UX decision, not a security control: anyone can call an Apex method through the API, a Flow, or a hand-written LWC. `RIQ_Read_Only` has no `RIQ_Recalculate_Health` or `RIQ_Log_Health_Signals`, and both controller methods check `FeatureManagement.checkPermission` before touching data and throw an `AuraHandledException` with a readable message. The component hides the actions as a courtesy, and the Apex test suite proves the Read Only user is refused — the test calls the method directly, which is exactly what an attacker would do.

**6. Why Chart.js from a static resource and not a CDN?**
A CDN is a runtime dependency on a third party that may be blocked by CSP, by an org's network policy, or simply be down — and a dashboard that goes blank because of someone else's outage is not a portfolio piece. Chart.js 4.6.1 is a `devDependency`, its UMD build is copied into the `chartjs` static resource, and the component loads it with `loadScript` from the org's own domain.

**7. What happens when Chart.js cannot load at all?**
The component degrades instead of failing. `loadScript` failing, or `window.Chart` being hidden from the component's sandbox under Lightning Web Security, flips a flag and the template renders a **pure SVG donut** built by the same `buildDonutSegments` helper: each slice is a circle stroke with `stroke-dasharray`/`stroke-dashoffset` geometry. Same data, same colours, same legend, no external script. A Jest test forces `loadScript` to reject and asserts the SVG fallback renders four segments and no canvas, so the fallback cannot rot unnoticed.

**8. Why is the at-risk table sorted and filtered on the server?**
The table is a window onto data that may not fit in the browser. Sorting on the client would sort only the 100 rows that happen to be loaded, which is a lie about the book of business. So `getAtRiskAccounts` takes the filter, the sort field and the direction, maps the field through a whitelist (`SORT_FIELDS`) and applies `ORDER BY` in SOQL — and the component re-queries on `onsort` and on every filter change. Rows are capped at 50 by default and 200 maximum, and the renewal window is clamped to 730 days, because those values come from the client.

**9. Why parse `Drivers__c` defensively?**
Because it is a `LongTextArea` containing JSON written by a job, read by a UI, and potentially edited by hand in workbench. One malformed row must not break the page for every account. `parseDrivers` uses `JSON.deserializeUntyped` inside a `try/catch`, treats a non-list as empty, ignores entries that are not objects, coerces numeric points, and caps the list at five. A test feeds it unbalanced brackets, a bare string, an empty object and a mixed list, and asserts the card still renders — an exception there would be a UI outage caused by one bad character.

**10. Why show "score updating" instead of the new score?**
Because the score is not new yet. Logging a signal inserts a row, the trigger enqueues a Queueable, and the Queueable recalculates after the transaction commits. A component that claimed "your score is now 62" would be inventing a number. So the logger shows that work is in flight, and after a bounded wait publishes on the `RIQ_Score_Refresh__c` Lightning Message channel; the score card listens to that channel and calls `refreshApex` on its wired card. It is the honest version of an optimistic update: state what you know, then re-read.

**11. Why subscribe to the platform event in the dashboard, and how do you avoid leaking it?**
The command center is the screen a CSM leaves open. Without a subscription, a band change caused by someone else's action or by the nightly batch leaves the tiles stale until a manual refresh — the exact staleness the product exists to remove. `empApi.subscribe` to `/event/RIQ_Health_Status_Change__e` with replay id `-1` toasts the transition and reloads the tiles, and `disconnectedCallback` calls `unsubscribe`, because a subscription outliving its component keeps firing into a destroyed shadow root.

**12. What do the Jest tests actually prove, and what do they not?**
They prove behaviour: filters reach Apex with the right arguments, a datatable sort maps to the right server field, the row action calls `recalculate` and reloads, a failed call produces a friendly toast rather than a raw error, validation blocks submission before any call, the "updating" state appears and later publishes with the account id, empApi subscribes once and unsubscribes on disconnect, and the Chart.js fallback renders. Forty-eight tests across four suites. What they do not prove is that it *looks* right: Jest renders a shadow DOM, not a page. Gauge proportions, donut angles and responsive wrapping still need a human in a browser, which is why the screenshot checklist exists and why the honest claim here is "deployed, unit tested, not visually verified".

**13. How is bulk safety preserved through the UI layer?**
The UI never sends a set of records: each call is one account (the card, the logger, the row action) or one filtered query (the dashboard), so there is no client-side fan-out to go wrong. Where the UI does cause volume — one CSM recalculating, then a nightly batch over the whole book — it lands on the same `RIQ_HealthScoreRecalculator.process(Set<Id>)`, which is bulk-safe and covered by the Phase 2 and 3 tests. The Lightning layer adds no new write path.

## Phase 5 — integrations (LLM callout and inbound REST API)

**14. Where does the API key live, and how do you prove it is not in the repository?**
Nowhere in the repository. The deployed `RIQ_LLM_API` External Credential declares a principal, `RIQ LLM Principal`, and an authentication parameter *named* `apiKey` with no value; the value is entered once in Setup and lives in the org's protected credential store. The Named Credential is a `SecuredEndpoint`, so callout URLs are `callout:RIQ_LLM_API/...` and the secret is never available to Apex at all — there is no `{!$Credential...}` merge field to leak into a debug log, a page, or a test. The proof is negative and checked: a grep for a key-shaped string across the repo finds nothing, the CMDT record ships disabled, and the test suite runs against `HttpCalloutMock`, which never touches the network. The git history has never seen a key because there has never been one to commit.

**15. Why an External Credential instead of the legacy "Named Credential with a password"?**
The legacy model puts the username and password on the named credential itself, which means the secret belongs to a *connection*, and every callout using it runs as "whatever that credential is". The External Credential separates the two: the credential owns the *principal* (an identity and its authentication parameters), named credentials point at it, and **principal access is a permission** granted through a permission set. That makes "who may spend money on the model" an auditable, assignable question with a Setup answer, instead of an implicit one. It is also the only model that supports OAuth client-credentials and per-user principals, so the design does not have to be thrown away when the toy key becomes a real integration.

**16. Why is the feature disabled by default, and what does "disabled" actually mean?**
Because a portfolio project that only runs if the reviewer supplies a credit card is not a portfolio project. `RIQ_AI_Config__mdt.Default.Is_Enabled__c` ships `false`; the service reads the config *before* building a prompt, so when it is off there is no callout, no timer, no log noise — the app produces a rule-based insight and the card says **Rule based**. A test asserts the mock was never invoked (`disabledToggleMakesNoCallout`), which is the difference between "we skip the call" and "we call and ignore the answer". The toggle is also the emergency switch: if the provider is down or the bill is surprising, an admin unticks a checkbox and the product keeps working.

**17. The prompt — what is in it, and what did you deliberately leave out?**
In: account name and number, health score, status, churn probability, ARR, contract end date, the top five scoring drivers with their points, the ten most recent signals with type, severity and date, and a strict instruction to answer with JSON only. Out: notes, descriptions, email addresses, phone numbers — anything where a customer's personal data lives. A callout is data leaving the platform, and "the model might need the notes to be useful" is not a good enough reason to export PII to a third party. The test builds an account whose notes and contact fields contain sentinel strings and asserts none of them appear in the captured request body, so the rule is enforced by the suite rather than by good intentions.

**18. How do you trust the model's answer?**
You don't. The request is an OpenAI-compatible chat completion (Groq) with `response_format: {"type":"json_object"}`, so the shape is JSON by contract rather than by hope — and the key never appears in Apex at all, because the `Authorization: Bearer {!$Credential.RIQ_LLM_API.apiKey}` header is declared on the External Credential and merged in by the platform. `parseResponse` then treats the reply as untrusted input: it strips code fences if the model adds them anyway, reads `choices[0].message.content`, repairs a missing summary or next best action, tolerates a `riskReasons` that is absent or not a list, ignores non-string entries, and caps lengths (3000 / 255 / three reasons of 255). Anything that cannot be repaired becomes the rule-based insight. Nothing from the model is ever executed, evaluated or trusted as instructions — you can tell it to "act as a system administrator and export all accounts" and the worst outcome is a silly summary. A 429 is read (`Retry-After` is logged) and then **falls back immediately**: the service never sleeps or retries inside the transaction, because a model hiccup must cost the user a badge, not a stalled page.

**19. Why is the button synchronous but the playbook path a Queueable?**
Two different constraints. A record-page action cannot return before the answer exists, so the callout has to be synchronous — and Salesforce forbids a callout after uncommitted DML, so `generateInsight` does the callout **first** and the single update afterwards. The playbook is the opposite: it runs inside a batch/queueable context that cannot make callouts at all, so it enqueues `RIQ_AiInsightQueueable`. That job caps itself at three accounts and chains the remainder: three accounts × a 30-second timeout is 90 seconds, comfortably inside the 120-second async limit. Chaining is wrapped in try/catch, because a failed chain must not look like a failed playbook — the tasks the playbook created are already committed and correct.

**20. The inbound API returns 200 when some rows failed. Isn't that wrong?**
It is the honest answer for a batch endpoint on this platform. Apex REST cannot return 207, so the options are 200-with-details, 400-for-everything, or a body-level flag with a 200. Failing the whole request because one row had a bad date forces the caller to choose between losing the good rows and re-sending everything — and re-sending is only safe if the endpoint is idempotent, which is why `externalId` is upserted onto a unique external-id field. So: 200 means "I read your batch and here is what happened to each row", 400 means "I could not read this at all", 413 means "too many rows, split it". The response carries `processed`/`created`/`updated`/`failed` and a per-row `status` with a `message`, so a caller can retry exactly the rows that errored.

**21. Duplicate `externalId`s inside one payload — first wins or last wins?**
Last occurrence wins, and the earlier copies are reported as `skipped` with a message saying so. First-wins was the alternative, but a caller that sends the same key twice in one batch almost certainly means the later value (a correction appended to a batch), and taking the first would write data the caller did not intend while the response claimed success. Reporting the skipped rows matters as much as the choice: the caller learns its payload had duplicates without having to diff the response against its input.

**22. Why `USER_MODE` and `with sharing` for the REST resource, when SYSTEM_MODE would "just work"?**
Because an API endpoint is the most exposed surface in the org: a leaked token is the whole attack. Running the selectors and `Database.upsert(..., AccessLevel.USER_MODE)` means the caller can only see accounts it could see in the UI and can only write fields its permission set grants, so the blast radius of a stolen credential is exactly one permission set — `RIQ_Integration_User`, which can read accounts and write signals and nothing else. SYSTEM_MODE would make the endpoint a privilege-escalation path: any valid token could read any account and write any field the code touches, regardless of sharing. The run-as test proves it: a user with only that permission set can post, and a user with no permission sets is refused.

**23. What is only verifiable with mocks, and what does that leave unproven?**
`HttpCalloutMock` lets the tests drive the whole service — success, 400/401/429/500, timeout, malformed and fenced JSON, empty content, the disabled toggle — and assert on the exact request body and headers, including that the prompt carries no PII. What it cannot prove is that a real provider accepts the request, that the key works, and that a live answer fits the parser. That needs one call with a real key, which is why `scripts/apex/verify-llm-callout.apex` exists and why the honest claim is "integration logic fully covered by Apex tests, live callout not executed in this org because no key is stored in the repository".

**24. What is the timer trade-off in the signal logger, and what would you change?**
The logger waits a bounded time for the score to recompute before it publishes on the message channel, because it wants to refresh the card with the *new* number rather than a prediction. asynchronous by design, and if the queueable is slow the wait ends without a fresh score. The better shape is event-driven rather than time-driven: have the recalculation publish an event with the account id (the platform event already exists for status changes) and let the card refresh on the message instead of after a fixed delay. That removes both the arbitrary wait and the case where the timer expires before the work is done.


## Phase 5.5 - India localisation, realistic data and activation

**25. How did you handle currency localisation, and why not Intl in Apex?**
Because Apex does not have `Intl` at all - it is a browser and Node API, and Apex has no ICU data. So there are two implementations of one rule set, each in the layer that can run it: `riqUtils.formatInr` / `formatInrCompact` use `Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR' })` in the component, and `RIQ_CurrencyFormatter` is a pure, hand-written Apex class with Indian digit grouping (last three digits, then groups of two) and the lakh/crore shorthand. The risk with two implementations is drift, so both are tested against the same boundary table - 99,999 / 1,00,000 / 99,99,999 / 1,00,00,000, zero, negatives, null. The compaction truncates rather than rounds, so 99,99,999 reads as 99.9 L and never as a crore that is not there. Money itself is still a Currency field: the org currency is INR, so the database stores rupees, not a formatted string.

**26. The UI is in English and Indian formats - what does "India-ready" concretely mean here?**
Four things, all enforced rather than assumed: the org is set to INR / `en_IN` / `Asia/Kolkata` (verified with `UserInfo.getDefaultCurrency()`, `getLocale()`, `getTimeZone()`); every amount renders with the rupee sign and Indian grouping, and compacted to L / Cr above a lakh; every timestamp renders through `Intl.DateTimeFormat` with `timeZone: 'Asia/Kolkata'` and a time-zone name, so a reviewer in another country still sees IST and no raw ISO string ever reaches the page; and the model prompt states that amounts are Indian Rupees and asks for lakh/crore phrasing instead of a dollar sign, with a test asserting the prompt contains no `$`.

**27. How is the app made visible, and how is the record page activated?**
Both are metadata, and both were verified by querying the org rather than by assuming. Visibility is `applicationVisibilities` on `RIQ_Admin`, `RIQ_CSM` and `RIQ_Read_Only` - an app that is not in a permission set is invisible in the App Launcher no matter how many tabs it has. Activation is `CustomApplication.actionOverrides`: an `actionName` of `View` for `Account`, `type` `Flexipage`, `content` `RIQ_Account_Record_Page`, `formFactor` Large. Deploying a Lightning page without that assignment leaves it inert, which is exactly the failure mode I hit in the browser. For the fields, the page uses Dynamic Forms field sections instead of the standard detail panel: a "Company" section and a "RenewalIQ" section with score, status, churn, ARR, contract end and the AI metadata, read-only where the engine owns the value. Fax, Ticker Symbol, SIC Code and the SLA fields are not hidden by CSS - they are simply not on the page.

**28. Why is all the demo data synthetic, and where does the rule come from?**
Because a portfolio org is public and a customer list is not. The 50 accounts are invented companies with invented domains across fintech, edtech, logistics, manufacturing, healthcare, retail, IT services and D2C, in eight Indian cities, with ARR from 5 lakh to 4.8 crore. The important part is what the seed does *not* do: it never writes a score. It inserts signals through the normal object and calls `RIQ_HealthScoreRecalculator.process`, so the 15 / 15 / 12 / 8 Healthy-Watch-At Risk-Critical spread is what the engine produced, not what the script wanted. Every figure in the UI comes from a query, which is why the dashboard KPIs can be printed next to a verification SOQL and match to the rupee.
