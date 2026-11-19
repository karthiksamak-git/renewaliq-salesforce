// Runs the nightly scoring batch once, outside the schedule, so a fresh org has
// scores from the same code path the 02:00 job uses (not from a fixture).
//
// Apex cannot sleep, so the batch finishes a few seconds after this returns. The
// job id is printed so the progress can be watched in Setup -> Apex Jobs.
//
//     sf apex run --file scripts/apex/run-nightly-batch.apex --target-org <alias>
Integer scopeSize = RIQ_NightlyScoreBatch.resolveBatchSize();
Id batchId = Database.executeBatch(new RIQ_NightlyScoreBatch(), scopeSize);

System.debug('Nightly batch started: ' + batchId + ' (scope size ' + scopeSize + ')');
System.debug('Watch it in Setup -> Apex Jobs, or re-read the scores after ~30 seconds.');
