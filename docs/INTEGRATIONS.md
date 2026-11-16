# RenewalIQ integrations

RenewalIQ talks to the outside world in exactly two directions, and both are
deliberately boring so that a reviewer can audit them in a few minutes.

| Direction | Mechanism | Entry point |
| --- | --- | --- |
| Outbound: write an account insight with a language model | External Credential + Named Credential (`RIQ_LLM_API`), called by `RIQ_AiInsightService` | `RIQ_AccountHealthController.generateInsight`, `RIQ_AiInsightQueueable` |
| Inbound: accept health signals from another system | Apex REST `@RestResource(urlMapping='/riq/v1/signals/*')` | `RIQ_SignalRestResource` |

Both are optional. With no API key and no inbound caller, every screen still
works: the insight falls back to rules and the signal logger still records
signals by hand.

---

## 1. Outbound: the LLM callout

### What is deployed

```
RIQ_LLM_API        External Credential   principal "RIQ LLM Principal", custom auth header
                                          x-api-key = {!$Credential.RIQ_LLM_API.apiKey}
RIQ_LLM_API        Named Credential      SecuredEndpoint, https://api.anthropic.com
RIQ_AI_Config__mdt Custom Metadata       one record "Default": Is_Enabled__c = false,
                                          Model_Name__c = claude-3-5-haiku-latest,
                                          Max_Tokens__c = 400, Timeout_Seconds__c = 30
RIQ_AI_Insight     Permission Set        principal access + RIQ_Generate_AI_Insight + AI fields
```

The class name is `RIQ_AiInsightService`; the async wrapper is
`RIQ_AiInsightQueueable`; the fields written are `RIQ_AI_Summary__c`,
`RIQ_Next_Best_Action__c`, `RIQ_AI_Risk_Reasons__c`, `RIQ_AI_Source__c` and
`RIQ_AI_Generated_On__c`.

### Setup: turn it on (5 minutes, once)

1. **Create the key** with the model provider (Anthropic, or any
   OpenAI-compatible provider if you follow §1.5). Do not paste it into a chat,
   a metadata file, a test, or this repository.
2. In Salesforce: **Setup → Named Credentials → External Credentials →
   `RIQ_LLM_API` → Principals → `RIQ LLM Principal`**.
3. Under **Authentication Parameters**, add a parameter named exactly
   `apiKey` and paste the key as its value. Save, then use **Test** — it should
   report success.
   *The key lives only in the org's protected credential store. Nothing in this
   repository contains it, and the deployed External Credential ships with the
   parameter name and no value.*
4. **Setup → Custom Metadata Types → `RIQ AI Config` → Manage Records →
   `Default` → Edit** and tick **Is Enabled**. This is the switch that decides
   whether any callout is attempted at all.
5. **Setup → Users → Permission Sets → `RIQ_AI_Insight`** (or `RIQ_Admin` /
   `RIQ_CSM`, which include it) and assign it to the users who may generate
   insights. The permission set grants *External Credential Principal Access*
   for `RIQ LLM Principal`, the custom permission `RIQ_Generate_AI_Insight`, and
   read/edit on the AI fields. Without the principal access the callout fails
   with an authentication error even when the key is correct — that is the
   single most common setup mistake.
6. Open an account record page. The health score card now shows
   **Generate AI insight**. Press it.

### Setup: turn it off

Untick **Is Enabled** on the `Default` record. The service checks the flag
before it builds a prompt, so no request leaves Salesforce, and the card writes a
rule-based insight instead. A test asserts that no callout is made when the
toggle is off (`RIQ_AiInsightService_Test.disabledToggleMakesNoCallout`).

### 1.1 The request

One POST to `callout:RIQ_LLM_API/v1/messages`, body:

```json
{
  "model": "claude-3-5-haiku-latest",
  "max_tokens": 400,
  "messages": [{ "role": "user", "content": "<deterministic prompt>" }]
}
```

`model`, `max_tokens` and `messages` are the intersection of the Anthropic and
OpenAI chat APIs, so the same body works against either. The timeout comes from
`Timeout_Seconds__c` (default 30s) and is set on the `HttpRequest`; callouts
therefore cannot run past the 120-second synchronous transaction limit in a way
that matters — the queueable caps itself at three accounts per job (§1.4).

### 1.2 The prompt, and what never goes into it

`RIQ_AiInsightService.buildPrompt` sends, for one account:

- name and `AccountNumber` (identifiers, needed to make the answer specific)
- health score, status, churn probability, ARR, contract end date
- up to five scoring drivers (name and points)
- the ten most recent signals (type, severity, date)
- an instruction to reply with JSON only: `{summary, nextBestAction, riskReasons[]}`

It never sends notes, descriptions, email addresses or phone numbers. Those
fields are where a customer's personal data lives, and a callout leaves the
platform. A test (`promptContainsNoFreeTextOrContactData`) builds an account
whose notes and contact fields contain sentinel strings and asserts that none of
them appear in the request body captured by the mock.

### 1.3 Defensive parsing and the fallback

The answer is treated as hostile input:

- code fences (```` ```json ````) are stripped before parsing
- both `content[0].text` (Anthropic) and `choices[0].message.content` (OpenAI)
  are accepted
- a missing `summary`, a missing `nextBestAction` and a non-list or missing
  `riskReasons` are repaired rather than thrown on
- summary is capped at 3000 characters, next best action at 255, at most three
  risk reasons of 255 characters each

Every failure path ends in the same place: a rule-based insight built from the
score, status, drivers and recent signals, stored with
`RIQ_AI_Source__c = 'Rule-based'`. The badge on the card reads **Rule based**
instead of **AI generated**, so a fallback is never mistaken for a model answer.

| Situation | Behaviour |
| --- | --- |
| toggle disabled | no callout, rule-based insight |
| timeout / callout exception | rule-based insight, reason logged at ERROR |
| HTTP 429, 5xx, 400, 401 | rule-based insight; the status code is logged, never shown to the user |
| malformed or fenced JSON | repaired when possible, otherwise rule-based |
| empty reply | rule-based |
| user without permission | `AuraHandledException` with a readable message, nothing written |

The user never sees a raw error, a stack trace or an HTTP status. The card gets
either a usable insight or a friendly sentence.

### 1.4 Where it runs, and why it is a Queueable

- **The button** (`generateInsight`) does the callout first, before any DML, then
  performs one update. That ordering is mandatory: Salesforce forbids a callout
  after uncommitted DML in the same transaction, and doing the callout first
  avoids the awkward alternative of a savepoint dance.
- **The playbook** (`RIQ_PlaybookService.run`) enqueues `RIQ_AiInsightQueueable`
  after its own DML, because a batch cannot call out. The queueable allows
  callouts, processes at most **three** accounts per job and chains the
  remainder, so a 200-account playbook run becomes ~67 short jobs instead of one
  job that dies at the 120-second async limit. A chain failure is caught and
  logged; the playbook result already committed is not rolled back.
- Nothing calls out from a trigger, from the batch, or from platform-event
  handling.

### 1.5 Switching to an OpenAI-compatible provider

1. **Setup → Named Credentials → `RIQ_LLM_API`**: change the URL to the
   provider's base URL (for OpenAI, `https://api.openai.com`).
2. **External Credential `RIQ_LLM_API` → `RIQ LLM Principal`**: change the
   header name from `x-api-key` to `Authorization` and the value to
   `Bearer {!$Credential.RIQ_LLM_API.apiKey}`, then re-enter the key. Anthropic's
   `anthropic-version: 2023-06-01` header can be removed at the same time.
3. **`RIQ AI Config` → `Default`**: set `Model_Name__c` to the provider's model
   id (for example `gpt-4o-mini`). No code change, no deployment.
4. The path is fixed at `/v1/messages`, which is Anthropic's. If the target
   provider only serves `/v1/chat/completions`, change the single constant
   `MESSAGES_PATH` in `RIQ_AiInsightService` and deploy. The response parser
   already reads both shapes, so nothing else changes.

### 1.6 Verify with one live call

After the key is in place and the config record is enabled, this single line
proves the whole chain (credential → named credential → request → parse →
write). Run it in **Developer Console → Execute Anonymous** or with
`sf apex run --target-org <alias> --file scripts/apex/verify-llm-callout.apex`.

```apex
Id accountId = [SELECT Id FROM Account ORDER BY LastModifiedDate DESC LIMIT 1].Id; System.debug(RIQ_AccountHealthController.generateInsight(accountId).aiSource);
```

It prints `AI` when the model answered and `Rule-based` when it fell back. No
key: it prints `Rule-based` and nothing leaves the org. Replace the query with a
specific account id to target a record.

### 1.7 Troubleshooting

| Symptom | Cause |
| --- | --- |
| always `Rule-based`, log says 401 | key wrong, or the authentication parameter is not named `apiKey` |
| log says 403 / "principal access" | user lacks External Credential Principal Access |
| nothing happens at all | `Is_Enabled__c` is still false |
| `AuraHandledException: You do not have permission` | `RIQ_Generate_AI_Insight` not assigned |
| works in one org, not another | `RIQ_LLM_API` points at a different base URL |

---

## 2. Inbound: the signal API

`POST /services/apexrest/riq/v1/signals` accepts up to 200 signals from another
system (a support tool, a usage warehouse, a CS platform) and writes them as
`RIQ_Health_Signal__c` rows, which triggers the normal recalculation.

The full contract — payload, response, status codes, idempotency and the
authentication options — is in [API.md](API.md). The two decisions worth
repeating here:

- **Idempotency is the `externalId` field.** It is upserted onto
  `RIQ_Health_Signal__c.RIQ_External_Key__c`, which is an *external id* and
  *unique*. Re-sending the same batch updates the same rows; it never
  duplicates them.
- **Partial success is HTTP 200 with per-row results.** Apex REST cannot return
  207, and failing the whole batch because one row was bad would force the
  caller to choose between losing the good rows and re-sending everything.

The endpoint runs `with sharing` and in `USER_MODE` throughout, so the caller's
own permissions decide what it can read and write. The dedicated
`RIQ_Integration_User` permission set is the minimum it needs.

---

## 3. What is verified, and how

Everything described above is covered by Apex tests that use `HttpCalloutMock`
and `Test.setMock`:

- `RIQ_AiInsightService_Test` — success, 400, 401, 429, 500, timeout, malformed
  JSON, fenced JSON, empty content, OpenAI shape, disabled toggle (asserts *no*
  callout), prompt privacy, parse hardening.
- `RIQ_AiInsightQueueable_Test` — batch cap and chaining, disabled toggle writes
  nothing, one failing account does not block the rest, large batch.
- `RIQ_SignalRestResource_Test` — single, 200 in one call, duplicate key, retry
  idempotency, invalid type, future date, unknown account, malformed JSON,
  oversized batch, per-row DML failure, and a run-as test with only
  `RIQ_Integration_User`.

**What the mocks do not prove:** that a real Anthropic endpoint accepts the
request, that the key is valid, and that the model's answer fits the parser in
practice. Those need one live call, which is §1.6. No credential is stored in the
repository, so that call has to be made by whoever holds the key.
