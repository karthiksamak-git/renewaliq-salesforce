#!/usr/bin/env node
/**
 * Fails the build if the Apex test run did not pass or if coverage dropped below
 * the gate. The numbers come from the Salesforce CLI's own output, so CI reads
 * exactly what the org reported — nothing is recalculated from source.
 *
 *   node scripts/ci/check-coverage.mjs test-results
 *
 * Gates:
 *   - every test passes (and the run is not empty)
 *   - org-wide coverage >= 90%
 *   - no single class or trigger below 85%
 *
 * The per-class gate was 75% (the platform's own deploy requirement) until Phase 8.
 * Every class now sits at 90% or above in a real org run, so the gate holds the
 * current floor instead of the platform minimum - a class that drops below 85%
 * fails CI long before it would fail a deployment.
 */
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const MIN_ORG_WIDE = 90;
const MIN_PER_CLASS = 85;
const dir = process.argv[2] ?? 'test-results';

let files;
try {
  files = readdirSync(dir);
} catch {
  console.error(`No results directory at ${dir}. Did the test run write its JSON output?`);
  process.exit(1);
}

const summaryFile = files.find(
  (file) =>
    file.startsWith('test-result-') &&
    file.endsWith('.json') &&
    !file.endsWith('-codecoverage.json') &&
    file !== 'test-result-codecoverage.json'
);

if (!summaryFile) {
  console.error(`No test result JSON found in ${dir}.`);
  process.exit(1);
}

const result = JSON.parse(readFileSync(join(dir, summaryFile), 'utf8'));
const summary = result.summary ?? {};
const testsRan = Number(summary.testsRan ?? 0);
const failing = Number(summary.failing ?? 0);
const orgWide = Number.parseInt(String(summary.orgWideCoverage ?? '0').replace('%', ''), 10);

console.log(`Tests run: ${testsRan}, failing: ${failing}, outcome: ${summary.outcome}`);
console.log(`Org-wide coverage: ${orgWide}%`);

const problems = [];

if (testsRan === 0) {
  problems.push('The test run reported zero tests. A silent zero-test run is worse than a failure.');
}
if (failing > 0) {
  problems.push(`${failing} test(s) failed.`);
}
if (summary.outcome && summary.outcome !== 'Passed') {
  problems.push(`The run outcome was ${summary.outcome}.`);
}
if (!Number.isFinite(orgWide) || orgWide < MIN_ORG_WIDE) {
  problems.push(`Org-wide coverage is ${orgWide}%, below the ${MIN_ORG_WIDE}% gate.`);
}

// Per class: the platform refuses a deployment whose class is below 75%, so CI
// fails at the same place the deploy would, only earlier and with a name.
let coverageFile;
try {
  coverageFile = JSON.parse(readFileSync(join(dir, 'test-result-codecoverage.json'), 'utf8'));
} catch {
  coverageFile = [];
}

const rows = coverageFile
  .map((row) => {
    const lines = Object.values(row.lines ?? {});
    const total = lines.length;
    const covered = lines.filter((hit) => Number(hit) > 0).length;
    return { name: row.name, total, covered, percent: total === 0 ? 100 : Math.round((covered / total) * 100) };
  })
  .sort((a, b) => a.percent - b.percent);

for (const row of rows) {
  if (row.percent < MIN_PER_CLASS) {
    problems.push(
      `${row.name} is at ${row.percent}% (${row.covered}/${row.total} lines), below the ${MIN_PER_CLASS}% gate.`
    );
  }
}

if (rows.length > 0) {
  console.log('\nLowest covered classes in this run:');
  for (const row of rows.slice(0, 5)) {
    console.log(`  ${row.name.padEnd(36)} ${String(row.percent).padStart(3)}%  (${row.covered}/${row.total})`);
  }
}

if (problems.length > 0) {
  console.error('\nCoverage gate failed:');
  for (const problem of problems) {
    console.error(`  - ${problem}`);
  }
  process.exit(1);
}

console.log(
  `\nCoverage gate passed: all tests green, org-wide ${orgWide}% (>= ${MIN_ORG_WIDE}%), no class below ${MIN_PER_CLASS}%.`
);
