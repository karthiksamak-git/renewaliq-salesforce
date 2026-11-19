## What changed

<!-- One or two sentences. If this fixes a bug, say what the bug looked like to a user. -->

## Why

<!-- The reason, not the diff. -->

## Checks I ran

- [ ] `npm run lint`
- [ ] `npm run prettier:verify`
- [ ] `npm run test:unit` (`__tests__` for LWC, 64 tests)
- [ ] `sf apex run test --code-coverage` — every class still at or above 90%
- [ ] `sf code-analyzer run --config-file config/code-analyzer.yml --workspace . --rule-selector pmd:RenewalIQApex` — 0 violations
- [ ] Deployed to a scratch org created from `config/project-scratch-def.json`

## Things reviewers should not have to guess

- [ ] No key, token, org auth URL or real customer data is in this diff
- [ ] Any new `SYSTEM_MODE` query or DML has a comment saying why `USER_MODE` cannot be used
- [ ] Any new suppression (`// NOPMD`) says why on the same line, and is listed in `docs/SECURITY.md`
- [ ] If a number appears in the UI or docs, it was measured, not estimated
