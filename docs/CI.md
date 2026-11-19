# CI/CD and scratch orgs

How this repository is verified, what it needs from you once, and what it cannot do
for itself. Everything below was either run (and the numbers are real) or is marked
as unrun.

## The two workflows

| Workflow               | Trigger                         | What it proves                                                                                                                 |
| ---------------------- | ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `ci.yml`               | every push and pull request     | Lint, formatting, Jest, then a **fresh scratch org**: deploy, permission sets, demo data, every Apex test, coverage gate, PMD. |
| `validate-dev-org.yml` | push to `main`, manual dispatch | A **check-only** deploy of the same metadata to the long-lived Developer Edition org, with local tests. Nothing is written.    |

`ci.yml` has two jobs. `lint-and-unit` needs nothing but Node. `apex-and-scratch`
needs a Dev Hub, so it is the one that has to know about secrets and forks.

### Why a check-only deploy as well as a scratch org

A scratch org proves the metadata is _complete_ — a component that only exists
because someone added it by hand in the Developer org cannot survive a fresh
deploy. The check-only validation proves the same commit still fits _this_ org,
which has the real demo data, a stored API key and two scheduled jobs. They fail
for different reasons, so both are worth having.

## Authentication: `SFDX_AUTH_URL`

CI cannot run `sf org login web` — nobody is there to click. Instead the Dev Hub
authorization is stored as a GitHub Actions secret in Salesforce's own "SFDX auth
URL" format, which is a `force://` URL containing the client id, the refresh token
and the instance URL.

```bash
sf org login web --set-default-dev-hub --alias devhub     # once, interactively
sf org display --verbose --target-org devhub              # copy the "Sfdx Auth Url" line
```

Then GitHub → Settings → Secrets and variables → Actions → **New repository
secret** → name `SFDX_AUTH_URL`, value the `force://…` URL. Paste it **once**, in
that form. Do not put it in a file, a commit, an issue, or a chat.

Optional second secret, `SFDX_AUTH_URL_DEVORG`, is the same value for the long-lived
Developer Edition org. `validate-dev-org.yml` skips itself cleanly when it is absent,
so adding it is not required to get a green run.

**How the workflow handles it:** the secret is written to `mktemp` with mode 600,
passed to `sf org login sfdx-url --sfdx-url-file`, and deleted in the same step.
`set -x` is never used, the value is never echoed, and it is not passed as a
command-line argument (arguments end up in process listings and error messages).

**Rotating it:** re-run `sf org login web` and `sf org display --verbose`, then update
the secret. Nothing in the repository changes.

### Why a fork cannot run the scratch-org job

A pull request from a fork runs with a read-only token and **no access to
repository secrets** — by design, because otherwise anyone could open a PR that
prints your refresh token. So `apex-and-scratch` is skipped when
`github.event.pull_request.head.repo.full_name` is not this repository. The
lint-and-unit job still runs, so a contributor's JavaScript and formatting are
still checked, and the skip is visible in the Actions tab rather than silent.

If you want Apex checked on fork PRs, the usual pattern is a maintainer applying a
label to trigger a second workflow via `workflow_run`; that adds a privilege
escalation path, so this repository does not do it.

## Developer Edition Dev Hub limits

A Developer Edition org can be a Dev Hub, and this project was built in one, but it
is a small Dev Hub:

- **Daily scratch org allowance is tiny** (a handful per day, and the exact number is
  not published). Every CI run creates one scratch org and deletes it afterwards. Two
  pushes in ten minutes can exhaust the day's allowance; the run then fails in
  `sf org create scratch` with a limit error, not in your code.
- **No sandboxes**, no second-generation packaging.
- **`ScratchOrgInfo` is minimal on this Dev Hub.** `Locale`, `TimeZone` and the other
  region columns are missing, so a definition file that sets them fails before any
  org exists:

  ```
  Error (INVALID_FIELD): No such column 'Locale' on sobject of type ScratchOrgInfo
  Error (INVALID_FIELD): No such column 'TimeZone' on sobject of type ScratchOrgInfo
  ```

  `config/project-scratch-def.json` is therefore deliberately small: org name,
  edition, one feature and three settings. Nothing is lost, because the properties
  that were removed only set defaults the project does not rely on — a scratch org
  inherits the Dev Hub's country, and this Dev Hub is Indian. Verified inside a fresh
  org rather than assumed: `UserInfo.getLocale()` returned **en_IN**,
  `getTimeZone()` **Asia/Kolkata** and `getDefaultCurrency()` **INR**, and the seeded
  book totals ₹23,64,00,000 across 50 accounts. If your Dev Hub does accept
  `locale`/`timeZone`/`country`, add them back; if it does not, this file is the shape
  that works.

- **Creation takes about 25-60 seconds** and deletion is immediate.

Because of the allowance, `ci.yml` uses `concurrency` with `cancel-in-progress` so a
second push cancels the first run (and its scratch org) instead of queueing another
one, and every job deletes its org in a `if: always()` step.

## The coverage gate

`sf apex run test --code-coverage --result-format json --output-dir test-results`
writes both a summary JSON and a per-class coverage JSON. `scripts/ci/check-coverage.mjs`
reads them and fails the build when:

- zero tests ran (a silent zero-test run is worse than a failure),
- any test failed,
- org-wide coverage is below **90%**,
- any single class or trigger is below **75%** — the platform's own deployment
  requirement, so CI fails at the same place a deploy would, only earlier and with
  a class name attached.

Current state: **190 tests, 0 failing**, **92% org-wide** in a fresh scratch org and
**90%** in the Developer org. Four classes sit below 90% in both —
`RIQ_HealthScoreRecalculator` 85%, `RIQ_NightlyScoreScheduler` 85%,
`RIQ_HealthSignalTriggerHandler` 86%, `RIQ_PlaybookService` 88% — all well above the
platform's 75% floor, so the gate passes. The honest statement is "every class is
above 85% and the org is at 90%", not "every class is at 90%"; closing that gap is
the next piece of test work, not something this document should claim.

## Static analysis in CI

```bash
sf code-analyzer run \
  --config-file config/code-analyzer.yml \
  --workspace . \
  --rule-selector pmd:RenewalIQApex \
  --severity-threshold 3 \
  --view table
```

`--severity-threshold 3` makes the command exit non-zero when a violation at
severity 3 (moderate) or worse is found, so the build fails on a real finding rather
than printing a table nobody reads. Inline `// NOPMD <reason>` suppressions are
honoured, which is why the accepted list in `docs/SECURITY.md` is part of the design
rather than a way to hide findings.

## Formatting versus PMD suppressions

`prettier-plugin-apex` rewrites a comment that follows an opening bracket onto its
own line. PMD only honours `// NOPMD` on the line it reports, so reformatting the
codebase would silently turn 13 suppressions into 13 violations — the build would go
from 0 to 13 while looking cleaner.

Two changes fixed it without weakening anything:

- the Apex override in `.prettierrc` sets `tabWidth: 4`, which is the indentation the
  project already used, so 53 files were already compliant;
- each statement whose suppression has to stay inline is preceded by
  `// prettier-ignore`, with a comment saying why. The NOPMD stays on the reported
  line, PMD stays at 0 violations, and `prettier --check` passes over the whole tree
  including Apex.

As a side effect, the seven empty extension hooks in `RIQ_TriggerHandler` now contain
an explicit `return;` instead of an empty block plus a suppression: one fewer
suppression to justify, and nothing for either tool to disagree about.

## What a fresh scratch org actually caught

Three things the Developer org could not tell me, all fixed in source:

1. **A metadata file that names one org's user.** `PlatformEventSubscriberConfig`
   sets the user the event trigger runs as, and a scratch org's admin username is
   generated. Shipping it with a real username would break every fresh deploy. It
   now lives in `config/platform-event/` as a template, the setup scripts render it
   with the target org's own username, and they delete the generated file straight
   after the deploy — leaving it behind made the _next_ full deploy to another org
   fail with `In field: User - no User named <scratch user> found`, which is exactly
   how it announced itself here.
2. **Two tests that assumed the event trigger shares the test's "today".** A platform
   event subscriber can run as a user in a different time zone, so `Date.today()`
   inside the trigger is not necessarily `Date.today()` in the test. In the Developer
   org the two happened to agree; in the scratch org the trigger was a day behind, so
   a task due date was off by one day and the 120-day renewal boundary flipped. The
   boundary is now asserted against the service's own predicate in a single context,
   the integration test uses accounts comfortably inside and outside the window, and
   the due date assertion allows one day with a comment saying why.
3. **`locale`, `timeZone` and `country` are not options on this Dev Hub.** Covered above.

## The scheduled-job problem

A deployment that contains a `Schedulable` class fails while that class has a job
**pending or in progress**:

```
This schedulable class has jobs pending or in progress
```

The nightly and log-cleanup jobs therefore block ordinary deployments. The cycle is:

```bash
sf apex run --file scripts/apex/abort-scheduled-jobs.apex --target-org devorg
sf project deploy start --target-org devorg --wait 45
sf apex run --file scripts/apex/schedule-jobs.apex --target-org devorg
```

A **check-only** validation does not need this, so `validate-dev-org.yml` does not
abort anything — aborting a scheduled job in a shared org to run a dry run would be
a side effect nobody asked for. If validation still reports the job error, the log
step prints the exact three commands above.

`scripts/setup.ps1` and `scripts/setup.sh` schedule the jobs _after_ the deploy for
the same reason.

## What a fresh clone caught

Cloning the repository into an empty folder and following only the README found one
more thing that no amount of testing in place would have: **238 files failed
`npm run prettier:verify` on Windows**, including `sfdx-project.json`, while the same
check passed in the working copy. The working copy was LF; git's `core.autocrlf`
handed a Windows checkout CRLF, and Prettier expects LF. A Linux CI run would have
been green while every Windows contributor saw a red check on untouched code.

`.gitattributes` now normalises everything (`* text=auto eol=lf`) with the binary
assets marked, so a checkout behaves the same on Windows, macOS and Linux. Re-cloning
after that change and running the quick start gave: `npm ci` clean, ESLint clean,
Prettier clean over 238 files, Jest 64/64.

## What is unverified until you push

- The GitHub-hosted runs themselves. Everything the workflows call was run locally on
  Windows against a real scratch org, and the YAML was checked, but the runner image,
  the `sf` version resolution and the Dev Hub allowance are GitHub's side.
- The `SFDX_AUTH_URL` secret, which by definition only exists in your repository.
- `scripts/setup.sh` — reviewed line by line against its PowerShell twin, not executed
  (this machine is Windows; the bash path has no macOS/Linux runner here).

The first run usually fails on something small (a pinned action version, a missing
plugin). Copy the failing step's log and fix that one thing.
