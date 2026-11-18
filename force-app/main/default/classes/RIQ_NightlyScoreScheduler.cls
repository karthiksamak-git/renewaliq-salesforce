/**
 * @description Owns the nightly schedule. Kept separate from the batch so the
 * schedule can be created, replaced or removed from a script without touching
 * batch logic, and so re-running the scheduler cannot create a second copy of
 * the job.
 */
public with sharing class RIQ_NightlyScoreScheduler implements Schedulable {
    /** Stable name used to find and replace the job. */
    public static final String JOB_NAME = 'RIQ Nightly Health Score';
    /** Daily at 02:00 in the scheduling user's time zone. */
    public static final String CRON_EXPRESSION = '0 0 2 * * ?';

    /**
     * @description Apex job entry point: launch the batch at the configured
     * size.
     * @param context Schedulable context supplied by the platform.
     */
    public void execute(SchedulableContext context) {
        Database.executeBatch(new RIQ_NightlyScoreBatch(), RIQ_NightlyScoreBatch.resolveBatchSize());
    }

    /**
     * @description Schedules the nightly run, replacing any existing job with
     * the same name. Safe to call repeatedly: an admin re-running this after a
     * time-zone change must not end up with two nightly batches racing each
     * other over the same accounts.
     * @return Id of the newly scheduled CronTrigger.
     */
    public static Id scheduleNightly() {
        abortExistingJobs();
        return System.schedule(JOB_NAME, CRON_EXPRESSION, new RIQ_NightlyScoreScheduler());
    }

    /**
     * @description Aborts every job already carrying this schedule's name.
     * Failures are logged rather than thrown: an admin should still get a
     * working schedule even if an old job has already finished.
     */
    private static void abortExistingJobs() {
        // NOPMD ApexCRUDViolation: CronTrigger is read-only system metadata with
        // no object or field permissions to check, and this class only ever
        // removes its own job name.
        List<CronTrigger> existingJobs = [ // NOPMD CronTrigger is system metadata with no FLS
            SELECT Id
            FROM CronTrigger
            WHERE CronJobDetail.Name = :JOB_NAME
        ];

        for (CronTrigger job : existingJobs) {
            try {
                System.abortJob(job.Id);
            } catch (Exception abortFailure) { RIQ_Logger.warn('RIQ_NightlyScoreScheduler', 'Could not abort a previous job.', abortFailure); }
        }
    }
}
