# RenewalIQ inbound signal API

`RIQ_SignalRestResource` lets an external system push health signals into
RenewalIQ without a Salesforce licence and without touching the UI. Signals are
what the scorer reacts to, so this is the integration a CS platform actually
wants.

```
POST /services/apexrest/riq/v1/signals
Content-Type: application/json
Authorization: Bearer <access token>
```

## Authentication

The endpoint is a normal Apex REST resource, so it authenticates like any
Salesforce API. There are two supported ways to get a token; both end with the
calls running as a dedicated integration user.

### Option A — External Client App with the client credentials flow (preferred)

1. **Setup → App Manager → New External Client App**, enable OAuth, and add the
   **API** scope (`api`). Do not enable any refresh-token or web-server flow.
2. Enable the **Client Credentials** flow and select a **Run As** user — the
   integration user described below.
3. Copy the consumer key and secret into the caller's secret store (never into
   this repository).
4. The caller exchanges them for a token:

```bash
curl -s https://login.salesforce.com/services/oauth2/token \
  -d grant_type=client_credentials \
  -d client_id="$SF_CLIENT_ID" \
  -d client_secret="$SF_CLIENT_SECRET" \
  -d scope=api
```

No user interaction, which is what a nightly job needs. The run-as user is
fixed by the app, so the token cannot exceed the integration user's permissions.

### Option B — Connected App with a JWT bearer flow

Same shape, but the caller signs a JWT with a certificate and posts
`grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=<jwt>`. Use this
when the caller already has a key pair and you would rather not store a secret.

### The integration user

Create one user whose whole job is this API, and assign exactly one permission
set: **`RIQ_Integration_User`**. It grants read on Account, create/edit on
`RIQ_Health_Signal__c`, and the field-level access the upsert needs — nothing
else, no UI, no reports. Keeping the identity separate means the API's blast
radius is visible in Setup, and rotating or disabling it does not touch a human's
access.

## Request

A JSON **array** of up to **200** signal objects. An object, a string or a
number is a 400.

| Field               | Type                 | Required       | Notes                                                                                                                                                                           |
| ------------------- | -------------------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `externalId`        | string, ≤ 120 chars  | yes            | Idempotency key. Unique across all signals, stable across retries.                                                                                                              |
| `accountId`         | string (18-char id)  | one of the two | Salesforce Account id.                                                                                                                                                          |
| `accountExternalId` | string, ≤ 40 chars   | one of the two | `Account.AccountNumber`, for callers that only know their own key.                                                                                                              |
| `signalType`        | string               | yes            | Must be a value of `RIQ_Health_Signal__c.Signal_Type__c`: `Support Escalation`, `Low Product Usage`, `Missed QBR`, `Executive Sponsor Left`, `Late Payment`, `NPS Detractor`, … |
| `severity`          | integer 1–5          | yes            | 5 is most severe. Values outside the range are rejected.                                                                                                                        |
| `occurredOn`        | `yyyy-MM-dd`         | yes            | Today or earlier; a future date is rejected rather than silently clamped.                                                                                                       |
| `notes`             | string, ≤ 5000 chars | no             | Free text stored on the signal.                                                                                                                                                 |

```bash
curl -s -X POST "https://your-domain.my.salesforce.com/services/apexrest/riq/v1/signals" \
  -H "Authorization: Bearer $SF_TOKEN" \
  -H "Content-Type: application/json" \
  -d '[
    {
      "externalId": "zendesk-ticket-88421",
      "accountExternalId": "NIVESH-001",
      "signalType": "Support Escalation",
      "severity": 4,
      "occurredOn": "2026-11-10",
      "notes": "P1 open for 3 days"
    },
    {
      "externalId": "usage-2026-11-10-NIVESH-001",
      "accountId": "001XXXXXXXXXXXXXXX",
      "signalType": "Low Product Usage",
      "severity": 3,
      "occurredOn": "2026-11-10"
    }
  ]'
```

## Response

**HTTP 200** — the body was accepted; look at each row.

```json
{
  "processed": 2,
  "created": 1,
  "updated": 0,
  "failed": 1,
  "results": [
    {
      "index": 0,
      "externalId": "zendesk-ticket-88421",
      "status": "created",
      "message": "Signal recorded.",
      "signalId": "a1BXXXXXXXXXXXXXXX"
    },
    {
      "index": 1,
      "externalId": "usage-2026-11-10-NIVESH-001",
      "status": "error",
      "message": "Account 001XXXXXXXXXXXXXXX does not exist or is not visible to you.",
      "signalId": null
    }
  ]
}
```

`status` is one of `created`, `updated` (the `externalId` already existed and the
row was refreshed — a retry), `skipped` (the same `externalId` appeared more than
once in this payload and this is not the last occurrence) or `error`.

### Status codes

| Code      | Meaning                                                                               |
| --------- | ------------------------------------------------------------------------------------- |
| 200       | Body parsed and every row was attempted. Read `results` for per-row outcomes.         |
| 400       | The body was empty, was not a JSON array, or was not valid JSON. Nothing was written. |
| 413       | More than 200 items. Nothing was written; split the batch.                            |
| 401 / 403 | Missing, expired or under-privileged token.                                           |
| 405       | The endpoint accepts `POST` only.                                                     |

There is no 207: Apex REST cannot return it, and inventing a body-level failure
for "some rows worked" would make the caller's retry overwrite the good rows.

## Idempotency

`externalId` is upserted onto `RIQ_Health_Signal__c.RIQ_External_Key__c`, an
external-id field with **unique** enforced. So:

- **Retrying a request is safe.** Rows that were already written come back as
  `updated`, not duplicated.
- **Duplicates inside one payload are resolved last-occurrence-wins**: the final
  copy is written, earlier copies are reported as `skipped`. The reasoning is
  that a caller sending the same key twice in one batch probably means the later
  value, and silently taking the first would make the response lie about which
  data landed.
- A payload whose rows fail validation can simply be corrected and re-sent; the
  good rows in the previous attempt are untouched.

## Bulk behaviour

- One query resolves every `accountId` / `accountExternalId` in the request, and
  one `Database.upsert` writes every row. No SOQL or DML inside a loop.
- Upsert is called with `allOrNone = false`, so a row that fails DML (for
  example a note longer than the target field) is reported as `error` while the
  rest are written.
- Each written signal fires the normal trigger path, so scores recompute
  asynchronously exactly as they do for signals logged in the UI. The API adds no
  second write path.

## Security notes

- **`with sharing` and `USER_MODE`.** The selectors and `Database.upsert` run in
  user mode, so the caller cannot read an account they could not otherwise see,
  and cannot write a field the integration user's permission set does not grant.
  SYSTEM_MODE was rejected on purpose: an API that ignores sharing is a
  privilege-escalation path waiting for a leaked token.
- **No guest access.** Apex REST requires authentication. Do not expose this
  class through a public site or an unauthenticated Experience Cloud page.
- **Least privilege.** `RIQ_Integration_User` is the minimum. It cannot edit
  accounts, cannot see opportunities, and cannot run the UI.
- **Logging.** Rejections carry a reason in the response; server-side
  `System.debug` output stays at ERROR level, and no token or payload is logged.
- **Rate.** The 200-item cap and the platform's own Apex REST limits bound the
  work per request; callers should retry 5xx with backoff and treat 429 from the
  platform the same way.
