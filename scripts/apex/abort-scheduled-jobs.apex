// Aborts every RenewalIQ scheduled job so a deployment is not blocked by
// "This schedulable class has jobs pending or in progress".
//
//     sf apex run --file scripts/apex/abort-scheduled-jobs.apex --target-org RenewalIQ
//
// Re-schedule afterwards with:
//     RIQ_NightlyScoreScheduler.scheduleNightly();
//     RIQ_LogCleanupBatch.schedule();
List<CronTrigger> jobs = [
    SELECT Id, CronJobDetail.Name, State, NextFireTime
    FROM CronTrigger
    WHERE CronJobDetail.Name LIKE 'RIQ%'
];

for (CronTrigger job : jobs) {
    System.debug('Aborting ' + job.CronJobDetail.Name + ' (' + job.State + ', next fire ' + job.NextFireTime + ').');
    System.abortJob(job.Id);
}

System.debug('Aborted ' + jobs.size() + ' RenewalIQ job(s).');
