# Security, quality and observability

This is the security story for RenewalIQ: what the app trusts, what it refuses,
how it proves the refusals, and what is still unverified.

Everything below was run against the development org (`RenewalIQ`, Developer
Edition, API 68.0). Numbers are from actual runs, not estimates.

---

## 1. Surfaces

| Surface                                                       | Who reaches it                                     | Trust level             |
| ------------------------------------------------------------- | -------------------------------------------------- | ----------------------- |
| Lightning Command Center (`riqCommandCenter`)                 | any user holding `RIQ_CSM` or `RIQ_Read_Only`      | untrusted browser       |
| Account record page (`riqHealthScoreCard`, `riqSignalLogger`) | same                                               | untrusted browser       |
| `@AuraEnabled` controllers                                    | the components above, and anyone who can call Apex | untrusted caller        |
| REST endpoint `/services/apexrest/riq/v1/signals`             | a machine account with `RIQ_Integration_User`      | untrusted network       |
| Model callout to Groq                                         | `RIQ_AiInsightService` only                        | third party             |
| Nightly batch and queueables                                  | the platform                                       | trusted, system context |

The design rule that follows from this table: **the browser and the API caller
are never trusted to decide what they are allowed to do.** Every mutation checks
a Custom Permission on the server, and every read runs in `USER_MODE`.

---

## 2. Access modes, and why each one

Selectors default to `USER_MODE`. Sharing is enforced by the platform for every
query, and by `with sharing` on the controllers. `SYSTEM_MODE` is used in six
places, each because the _platform_, not a person, is the actor:

| Location                                                             | Why system context                                                                                                                                                          | Risk accepted                                                               |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| `RIQ_HealthScoreRecalculator` (`without sharing`, `SYSTEM_MODE` DML) | the score fields are system-maintained; `RIQ_CSM` can read them but must not edit them, so a user-context write would silently fail for exactly the person logging a signal | ids come from records that user just touched; only score fields are written |
| `RIQ_NightlyScoreBatch.start()`                                      | the nightly run must score the whole book, not one owner's slice                                                                                                            | read-only, ids only                                                         |
| `RIQ_PlaybookService`                                                | the event subscriber runs as the Automated Process user, which owns no accounts and holds no permission set                                                                 | creates a Task and an Opportunity for the account owner                     |
| `RIQ_AiInsightQueueable`                                             | background job, no interactive user present                                                                                                                                 | writes only the five AI fields                                              |
| `RIQ_Logger.persist()`                                               | the subscriber runs as the Automated Process user, and the line may describe a record the reader cannot see                                                                 | payload is already redacted, see §6                                         |
| `RIQ_LogCleanupBatch`                                                | retention is a maintenance duty; no UI role is granted delete on `RIQ_Log__c`                                                                                               | deletes only rows older than the configured window                          |

Every one of those calls carries an inline comment saying so. That is deliberate:
`SYSTEM_MODE` should be tombstones, not scenery.

---

## 3. Findings and fixes

Severity is by exploitability in a real org, not by how hard the fix was.

| #   | Severity | File                                           | Issue                                                                                                                                           | Fix                                                                           |
| --- | -------- | ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| 1   | **High** | `RIQ_SignalRestResource.describeErrors`        | returned the platform's raw DML message to the API caller — field names, record ids and picklist internals — while a comment claimed it did not | returns one fixed sentence; the detail goes to `RIQ_Log__c`                   |
| 2   | Medium   | `RIQ_AccountHealthController.logSignal`        | `notes` was not length-checked before DML, so an oversized payload produced a platform error instead of a message                               | validated against the 5 000 character field, refused with a friendly sentence |
| 3   | Medium   | 8 classes                                      | failures were written to `System.debug` only, so a production incident left no evidence after the request ended                                 | `RIQ_Logger` + `RIQ_Log__c` through a Publish Immediately platform event      |
| 4   | Medium   | `RIQ_PlaybookService`, `RIQ_NightlyScoreBatch` | inline SOQL ran in the class's implicit mode with no stated reason                                                                              | explicit `WITH SYSTEM_MODE` plus a comment at each site                       |
| 5   | Low      | `RIQ_AccountHealthController.parseDrivers`     | `System.debug` on a cacheable read path                                                                                                         | documented suppression: a cacheable method may not publish an event           |
| 6   | Low      | `RIQ_Selector`                                 | declares no sharing keyword                                                                                                                     | intentional: it inherits the caller's mode, and the comment says so           |

No hardcoded record ids, no credentials, no `without sharing` controller, and no
AuraEnabled method that returns raw exception text. The two controllers and the
REST resource all declare `with sharing`.

### SOQL injection

There is no string-concatenated user input anywhere. Every query is dynamic
`Database.queryWithBinds` with real bind variables (`RIQ_Selector`), or inline
SOQL with a bind. The only interpolated fragments are a whitelisted sort field
(`SORT_FIELDS` map) and a whitelisted direction (`ASC`/`DESC`), both resolved
before they reach the query string. `escapeSingleQuotes` is not used because
there is nothing to escape: no caller value is ever concatenated.

---

## 4. Permission matrix

Five permission sets, no profile customisation. A user needs exactly one of them
plus the standard objects they already use.

| Capability                                          | `RIQ_Admin`     | `RIQ_CSM` | `RIQ_Read_Only` | `RIQ_Integration_User` | `RIQ_AI_Insight` |
| --------------------------------------------------- | --------------- | --------- | --------------- | ---------------------- | ---------------- |
| See RenewalIQ in the App Launcher                   | yes             | yes       | yes             | no                     | —                |
| Command Center tab                                  | yes             | yes       | yes             | no                     | —                |
| Read score, status, ARR, contract end               | yes             | yes       | yes             | no                     | —                |
| Read health signals                                 | yes             | yes       | yes             | no                     | —                |
| Create / edit health signals                        | yes             | yes       | no              | create + edit          | no               |
| Delete health signals                               | yes             | no        | no              | no                     | no               |
| Recalculate a score (`RIQ_Recalculate_Health`)      | yes             | yes       | no              | no                     | no               |
| Log a signal from the UI (`RIQ_Log_Health_Signals`) | yes             | yes       | no              | no                     | no               |
| Generate an AI insight (`RIQ_Generate_AI_Insight`)  | yes             | yes       | no              | no                     | yes              |
| Call the model (External Credential principal)      | yes             | yes       | no              | no                     | yes              |
| Post signals to the REST endpoint                   | —               | —         | —               | yes                    | —                |
| Read `RIQ_Log__c` / see Recent errors               | yes (read only) | no        | no              | no                     | no               |
| Run the retention job                               | yes             | no        | no              | no                     | no               |

`RIQ_AI_Insight` is deliberately separable: it grants the model call and _not_
the right to change a score or a signal, so a data analyst can be given insight
generation without being given a CSM's write access.

### What the tests actually prove

`RIQ_SecurityModel_Test` runs seven personas with `System.runAs`, calling the
real entry points:

- a Read-Only user reads the card, and is refused by `recalculate`, `logSignal`
  and `generateInsight` with a message that contains the word "permission";
- a Read-Only user is also refused by `Database.insert(..., USER_MODE)`, so the
  refusal is the platform's, not just a `if` statement;
- a CSM can recalculate and log, and cannot exceed the notes limit;
- the Integration user can post one signal through the REST resource and cannot
  recalculate or spend a model call;
- a user with `RIQ_Read_Only` + `RIQ_AI_Insight` can generate an insight, cannot
  recalculate, and gets `Rule-based` when no callout is possible;
- an Administrator can do all three.
- Seven users across five permission sets pass. 189 tests, 0 failing.

The persona users are created in `@TestSetup`: `User` and
`PermissionSetAssignment` are setup objects, and mixing them with `Account` DML
in one transaction raises `MIXED_DML_OPERATION`.

---

## 5. Secrets

A key pasted into chat is a burned key. The current design makes that the only
way to leak one:

- The provider key lives in **Setup → Named Credentials → External Credentials →
  `RIQ_LLM_API` → `RIQ LLM Principal` → `apiKey`**. It is not deployable and not
  in source. Apex references the credential by name only
  (`callout:RIQ_LLM_API`), and the `Authorization` header is merged in by the
  platform.
- `scripts/apex/verify-llm-callout.apex` prints the _source_ of the insight
  (`AI` or `Rule-based`), never the key.
- `RIQ_Logger` redacts provider-key shapes (`gsk_`, `sk-`, `sk-ant-`,
  `sk-proj-`, `xox[baprs]-`), bearer tokens, `key=value` style secrets, email
  addresses and long numbers before a line is stored.

### Secret scan

Run against the working tree and the full history:

```
git grep -n -i -E "gsk_|sk-[a-zA-Z0-9]{16,}|sk_live_|sk_test_|xox[baprs]-"
git log -p --all | grep -n -i -E "gsk_[a-zA-Z0-9]{10,}|sk-[a-zA-Z0-9]{20,}"
```

Results are reported in the phase summary. The repository contains no key, no
`Authorization: Bearer <value>` with a real token, and no `.env` file. The only
`Bearer` occurrences are the metadata placeholder
`{!$Credential.RIQ_LLM_API.apiKey}`.

---

## 6. Data minimisation for the model

`RIQ_AccountSelector.getForAiInsight` selects exactly six fields: name, ARR,
contract end date, score, status, id. The prompt adds signal _type_, severity and
date — never `Notes__c`, never a contact name, email or phone. `RIQ_AiInsightService`
also refuses to echo model output verbatim into a field without capping it
(3 000 / 255 / three reasons of 180 characters).

The rule is enforced by a test that puts sentinel strings in the account's notes
and contact fields and asserts they do not appear in the captured request body.

---

## 7. Logging

`RIQ_Logger` writes one line per event through `RIQ_Log_Event__e`, a platform
event defined with **Publish Immediately**. That behaviour is the whole design:
the subscriber (`RIQ_LogEventTrigger`) writes `RIQ_Log__c` in a separate
transaction, so a line logged inside a transaction that later rolls back is still
stored. Salesforce documents Publish Immediately as the right choice for exactly
this case.

- Fields: `Level__c` (Error / Warning / Info), `Source__c`, `Message__c`,
  `Stack_Trace__c`, `Related_Id__c`, `Logged_At__c`.
- Payload text is capped at 255 characters because platform event text fields
  are; `getStackTraceString()` starts at the innermost frame, so the truncation
  keeps the line that failed.
- The logger never throws. If publishing fails or the publish budget is
  exhausted, it degrades to `System.debug` and the user's page still works.
- `RIQ_Log__c` is read-only for administrators and has no delete for any UI role,
  so the audit trail cannot be quietly erased by hand.
- Admin list view **Recent errors** filters `Level = Error`, newest first.

### Retention

`RIQ_LogCleanupBatch` deletes rows older than `RIQ Batch Config → Log Retention
Days` (default 30) at 03:00 daily, bounded to 50 000 rows per run. Retention is
configurable without a deployment, and `Logged_At__c` exists specifically so the
window can be tested — `CreatedDate` is not writable, and an untestable retention
rule is a rule nobody knows works.

Schedule it once with:

```
sf apex run --file scripts/apex/schedule-log-cleanup.apex --target-org RenewalIQ
```

---

## 8. Static analysis

PMD for Apex, through Salesforce Code Analyzer v5, configured in
`config/code-analyzer.yml` with the ruleset in `config/pmd-ruleset.xml`. The
ruleset enforces three whole categories — security, performance, error-prone —
rather than a hand-picked list, so a new defect class is covered the day PMD
knows about it.

It was run with the JBR bundled with Android Studio (there is no system JDK on
this machine):

```
export JAVA_HOME="/c/Program Files/Android/Android Studio/jbr"
sf code-analyzer run --config-file config/code-analyzer.yml \
    --workspace . --rule-selector pmd:RenewalIQApex --view table
```

**Result: 0 violations.**

> A ruleset file cannot contain a double hyphen inside an XML comment, and the CLI
> flags in this document start with two hyphens — which is why the command lives
> here and not in `pmd-ruleset.xml`. PMD refuses to parse the file otherwise.

### Accepted suppressions

Each one is an inline `// NOPMD` with the reason on the same line.

| Rule                         | Files                                                                                                  | Why it is accepted                                                                                                                                                                                                        |
| ---------------------------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AvoidDebugStatements`       | `RIQ_Logger` (3), `RIQ_Logger_Test` (1), `RIQ_Performance_Test` (2), `RIQ_AccountHealthController` (2) | the logger's own failure paths have nowhere else to report; the performance test's debug line _is_ the measurement report; the two controller lines run on a cacheable read path where publishing an event is not allowed |
| `ApexCRUDViolation`          | `RIQ_ScoringRuleProvider` (2), `RIQ_AiInsightService`, `RIQ_NightlyScoreScheduler`                     | custom metadata has no FLS or sharing to enforce, and `CronTrigger` is read-only system metadata                                                                                                                          |
| `AvoidNonRestrictiveQueries` | `RIQ_NightlyScoreBatch`                                                                                | an unfiltered read of signal account ids is the point of the batch scope                                                                                                                                                  |
| `ApexSharingViolations`      | `RIQ_Selector`                                                                                         | the base class deliberately inherits the caller's mode; declaring `with sharing` would silently change the system-context callers                                                                                         |
| `EmptyStatementBlock`        | `RIQ_TriggerHandler` (7)                                                                               | the seven empty virtual methods are the extension points                                                                                                                                                                  |

Two real defects were found and fixed by the tool rather than suppressed:

- a SOQL query and a DML inside a loop in `RIQ_TestDataFactory` — now one query
  and one insert for the whole permission-set list;
- eight hardcoded-looking id literals in tests — replaced by
  `RIQ_TestDataFactory.nonExistentAccountId()`, which builds a 15-character id
  from the real key prefix at runtime.

ESLint and Prettier cover the Lightning components; `npm run lint` and
`npm run prettier:verify` are clean. Prettier for Apex cannot run on this machine
(Device Guard blocks the `apex-ast-serializer` native binary), which is why the
Apex formatting check belongs in CI, not here.

---

## 9. Performance

`RIQ_Performance_Test` builds 200 accounts with 15 signals each (3 000 signals)
and scores them in one chunk, then runs the real nightly batch over the same
book. Signals are inserted with the trigger bypassed, so the measurement is the
calculation rather than the fixture.

Observed on a real run:

| Measurement                              | Observed       | Threshold in the test | Platform limit    |
| ---------------------------------------- | -------------- | --------------------- | ----------------- |
| SOQL statements, one 200-account chunk   | **4**          | 10                    | 100               |
| DML statements, one 200-account chunk    | **2**          | 4                     | 150               |
| CPU time, one 200-account chunk          | **1 642 ms**   | 10 000 ms             | 10 000 ms (sync)  |
| Nightly batch, 200 accounts in one chunk | **915 ms** CPU | —                     | 60 000 ms (async) |

Four queries is the whole cost: accounts, signals, scoring rules, thresholds —
all bulk, none per account. Two DML statements are the account update and the
history insert. The thresholds are set an order of magnitude below the platform
limits on purpose: a chunk using 10 % of its budget has room to grow, and a
regression shows up as a red test rather than a half-scored book in production.

---

## 10. What is not verified

Stated plainly, because a security document that overclaims is worse than none.

1. **No user has been logged in as.** The org is at its Salesforce licence limit
   (both Standard licences are in use), so the throwaway Read-Only and CSM users
   this phase called for could not be created. The permission sets are verified
   by retrieval — `applicationVisibilities` for RenewalIQ is present on
   `RIQ_Admin`, `RIQ_CSM` and `RIQ_Read_Only`, and `SetupEntityAccess` shows
   `RIQ_Read_Only` granting the RenewalIQ tab set and both controller classes.
   Whether the App Launcher _renders_ the tile for such a user still needs one
   `Log in as` check.
2. **The live model callout is unverified in this org.** The key cannot be
   deployed, so `RIQ_AI_Config.Default` ships disabled and the tests prove the
   rule-based path and the request shape with a mock. One real call is still
   outstanding, and `docs/INTEGRATIONS.md` has the steps and the troubleshooting
   table for it.
3. **Nothing was seen in a browser.** Layout, focus rings, badge rendering and
   mobile wrapping remain visually unverified.
4. **Prettier for Apex** was not run (Device Guard blocks the binary). The Apex
   subset of `prettier:verify` is therefore a CI-only check.
