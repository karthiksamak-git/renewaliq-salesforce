/**
 * @description Enforces log retention.
 *
 * A log that grows forever is a storage bill and a data-protection problem, so
 * the retention window is explicit, configurable and tested. RIQ_Log__c carries
 * its own Logged_At__c because CreatedDate cannot be written by a test, and an
 * untestable retention rule is a rule nobody knows works.
 *
 * One class implements both Batchable and Schedulable so the schedule and the
 * work cannot drift apart. The bounded row limit keeps a single run inside the
 * batch transaction budget; a backlog simply takes another night, which is
 * correct for a cleanup job.
 */
public with sharing class RIQ_LogCleanupBatch implements Database.Batchable<SObject>, Database.Stateful, Schedulable {
    /** Used when RIQ_Batch_Config__mdt has no usable value. */
    public static final Integer DEFAULT_RETENTION_DAYS = 30;
    /** Rows deleted per run; a safety valve, not a target. */
    public static final Integer MAX_ROWS_PER_RUN = 50000;
    /** Stable name so re-running the schedule replaces it. */
    public static final String JOB_NAME = 'RIQ Log Retention Cleanup';
    /** Daily at 03:00, an hour after the nightly score run. */
    public static final String CRON_EXPRESSION = '0 0 3 * * ?';

    /** Rows deleted across every chunk of this run. */
    public Integer deletedCount = 0;

    /** Days of history to keep for this run. */
    public final Integer retentionDays;

    /** Reads the retention window from configuration. */
    public RIQ_LogCleanupBatch() {
        this(resolveRetentionDays());
    }

    /**
     * @param days Days to keep. Non-positive values fall back to the default.
     */
    public RIQ_LogCleanupBatch(Integer days) {
        this.retentionDays = days == null || days < 1 ? DEFAULT_RETENTION_DAYS : days;
    }

    /**
     * @description Schedulable entry point: launches the batch.
     * @param context Schedulable context supplied by the platform.
     */
    public void execute(SchedulableContext context) {
        Database.executeBatch(new RIQ_LogCleanupBatch(), 200);
    }

    /**
     * @param context Batch context supplied by the platform.
     * @return Locator over expired rows.
     */
    public Database.QueryLocator start(Database.BatchableContext context) {
        DateTime cutoff = DateTime.now().addDays(-retentionDays);

        return Database.getQueryLocator(
            [
                SELECT Id
                FROM RIQ_Log__c
                WHERE Logged_At__c < :cutoff
                ORDER BY Logged_At__c
                LIMIT :MAX_ROWS_PER_RUN
            ]
        );
    }

    /**
     * @description Deletes one chunk. SYSTEM_MODE on purpose: this is a
     * maintenance job, the rows are operational metadata rather than customer
     * records, and nobody is granted delete on RIQ_Log__c in the UI - least
     * privilege means an administrator cannot quietly erase the audit trail by
     * hand, while the scheduled job still enforces its retention window.
     * @param context Batch context supplied by the platform.
     * @param scope Expired rows in this chunk.
     */
    public void execute(Database.BatchableContext context, List<SObject> scope) {
        if (scope == null || scope.isEmpty()) {
            return;
        }

        for (Database.DeleteResult result : Database.delete(scope, false, AccessLevel.SYSTEM_MODE)) {
            if (result.isSuccess()) {
                deletedCount++;
            } else {
                RIQ_Logger.warn('RIQ_LogCleanupBatch', 'Could not delete one log row.');
            }
        }
    }

    /**
     * @param context Batch context supplied by the platform.
     */
    public void finish(Database.BatchableContext context) {
        String jobId = context == null || context.getJobId() == null ? 'unknown' : String.valueOf(context.getJobId());

        RIQ_Logger.info(
            'RIQ_LogCleanupBatch',
            'Log retention run finished: ' + deletedCount + ' row(s) older than ' + retentionDays + ' days deleted.',
            jobId
        );
    }

    /**
     * @description Schedules the nightly cleanup, replacing any existing job
     * with the same name.
     * @return Id of the newly scheduled job.
     */
    public static Id schedule() {
        List<CronTrigger> existing = [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :JOB_NAME];

        for (CronTrigger job : existing) {
            abortQuietly(job.Id);
        }

        return System.schedule(JOB_NAME, CRON_EXPRESSION, new RIQ_LogCleanupBatch());
    }

    /**
     * @description Aborts one job without letting a stale schedule stop the new
     * one from being created. Test-visible so the failure branch is provable: a
     * job id that no longer exists is exactly what an admin hits after a manual
     * abort in Setup.
     * @param jobId CronTrigger to remove.
     */
    @TestVisible
    static void abortQuietly(Id jobId) {
        try {
            System.abortJob(jobId);
        } catch (Exception abortFailure) {
            RIQ_Logger.warn('RIQ_LogCleanupBatch', 'Could not abort the previous cleanup job.', abortFailure);
        }
    }

    /**
     * @return Configured retention in days, never less than one.
     */
    public static Integer resolveRetentionDays() {
        List<RIQ_Batch_Config__mdt> configs = [SELECT Log_Retention_Days__c FROM RIQ_Batch_Config__mdt LIMIT 1];

        if (configs.isEmpty() || configs[0].Log_Retention_Days__c == null) {
            return DEFAULT_RETENTION_DAYS;
        }

        Integer configured = configs[0].Log_Retention_Days__c.intValue();
        return configured < 1 ? DEFAULT_RETENTION_DAYS : configured;
    }
}
