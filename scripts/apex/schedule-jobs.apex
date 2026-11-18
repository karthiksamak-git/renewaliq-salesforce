// Re-schedules both RenewalIQ jobs after a deployment.
//
// A deployment is blocked while a Schedulable class has a job pending, so the
// usual cycle is: abort (scripts/apex/abort-scheduled-jobs.apex), deploy, then
// run this. Both calls replace any existing job with the same name, so running
// it twice cannot produce two nightly batches.
//
//     sf apex run --file scripts/apex/schedule-jobs.apex --target-org RenewalIQ
Id nightlyId = RIQ_NightlyScoreScheduler.scheduleNightly();
Id cleanupId = RIQ_LogCleanupBatch.schedule();

System.debug('Nightly score job: ' + nightlyId);
System.debug('Log retention job: ' + cleanupId);

// Proof, not intent: read the schedule back.
for (CronTrigger job : [
    SELECT CronJobDetail.Name, State, NextFireTime
    FROM CronTrigger
    WHERE CronJobDetail.Name LIKE 'RIQ%'
    ORDER BY CronJobDetail.Name
]) {
    System.debug(job.CronJobDetail.Name + ' | ' + job.State + ' | next fire ' + job.NextFireTime);
}
