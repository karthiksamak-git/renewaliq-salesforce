// Schedules the RenewalIQ log retention job, replacing any existing one.
//
// Run it in the Developer Console (Debug > Open Execute Anonymous Window) or:
//     sf apex run --file scripts/apex/schedule-log-cleanup.apex --target-org RenewalIQ
//
// Retention is read from RIQ Batch Config (Log Retention Days), default 30.
// Daily at 03:00, an hour after the nightly score run.
Id jobId = RIQ_LogCleanupBatch.schedule();
System.debug('Scheduled: ' + jobId + ', keeping ' + RIQ_LogCleanupBatch.resolveRetentionDays() + ' day(s) of logs.');

// Proof, not intent: read the schedule back.
for (CronTrigger job : [
    SELECT CronJobDetail.Name, State, NextFireTime
    FROM CronTrigger
    WHERE CronJobDetail.Name = :RIQ_LogCleanupBatch.JOB_NAME
]) {
    System.debug(job.CronJobDetail.Name + ' | ' + job.State + ' | next fire ' + job.NextFireTime);
}
