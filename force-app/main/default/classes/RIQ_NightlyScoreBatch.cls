/**
 * @description Nightly re-score of the whole book of business.
 *
 * Why this exists even though logging a signal already queues a recalculation:
 * scores are time-decayed. An account that has not been touched for a month
 * still gets healthier as its escalations age out, and nothing fires a trigger
 * to say so. The batch is the clock of the model.
 *
 * It calls RIQ_HealthScoreRecalculator.process() directly, one call per chunk,
 * instead of enqueueing a Queueable per account: a batch chunk is already an
 * async, isolated transaction with its own governor limits, and enqueueing from
 * inside it would burn the 50-job limit and make the job's own progress
 * impossible to report.
 *
 * Stateful counters survive chunk boundaries, so finish() reports the run the
 * way an operator needs to read it: processed / band changes / failures.
 */
public with sharing class RIQ_NightlyScoreBatch implements Database.Batchable<SObject>, Database.Stateful {
    /** Used when RIQ_Batch_Config__mdt has no usable record. */
    public static final Integer DEFAULT_BATCH_SIZE = 200;

    /** Accounts loaded and scored across every chunk. */
    public Integer processedCount = 0;
    /** Real health-band transitions across every chunk. */
    public Integer statusChangeCount = 0;
    /** Accounts scored for the first time (baseline, no event). */
    public Integer initialScoreCount = 0;
    /** Failed updates, history rows and events across every chunk. */
    public Integer failureCount = 0;
    /** Chunks executed. */
    public Integer chunkCount = 0;

    /**
     * @description Scope: every customer the model can say something about.
     * Either we know its contract value (so it is a real renewal) or it has at
     * least one health signal (so there is evidence to score). Accounts with
     * neither are prospects and are deliberately left alone.
     *
     * The signal set is materialised into a bind first because SOQL forbids a
     * semi-join sub-select under OR ("Semi join sub-selects are not allowed
     * with the 'OR' operator"). One extra query buys a single, chunkable
     * QueryLocator over the union of both conditions.
     *
     * @param context Batch context supplied by the platform.
     * @return Locator over the in-scope Accounts.
     */
    public Database.QueryLocator start(Database.BatchableContext context) {
        Set<Id> accountIdsWithSignals = new Set<Id>();

        // SYSTEM_MODE on purpose: the nightly run is a maintenance job that must
        // score the whole book of business, not the subset its scheduling user
        // happens to own. It writes only system-maintained score fields and
        // reads no free text.
        // AvoidNonRestrictiveQueries: an unfiltered read here is the point. The batch
        // has to know every account that has any signal at all; a restrictive filter
        // would silently shrink the book of business. The NOPMD has to stay on the
        // line PMD reports, so the formatter is told to leave the loop alone.
        // prettier-ignore
        for (RIQ_Health_Signal__c signal : [SELECT Account__c FROM RIQ_Health_Signal__c WITH SYSTEM_MODE]) { // NOPMD unfiltered read is the point
            if (signal.Account__c != null) {
                accountIdsWithSignals.add(signal.Account__c);
            }
        }

        return Database.getQueryLocator(
            [
                SELECT Id
                FROM Account
                WHERE RIQ_ARR__c != NULL OR Id IN :accountIdsWithSignals
                WITH SYSTEM_MODE
            ]
        );
    }

    /**
     * @description Scores one chunk through the same service the real-time path
     * uses, then accumulates the counters.
     * @param context Batch context supplied by the platform.
     * @param scope Accounts in this chunk.
     */
    public void execute(Database.BatchableContext context, List<SObject> scope) {
        if (scope == null || scope.isEmpty()) {
            return;
        }

        chunkCount++;
        RIQ_HealthScoreRecalculator.ProcessResult result = RIQ_HealthScoreRecalculator.process(
            new Map<Id, SObject>(scope).keySet()
        );

        processedCount += result.processedCount;
        statusChangeCount += result.statusChangeCount;
        initialScoreCount += result.initialScoreCount;
        failureCount += result.failureCount;
    }

    /**
     * @description One summary line per run. Phase 6 replaces System.debug with
     * RIQ_Logger; until then the debug log is the log.
     * @param context Batch context supplied by the platform.
     */
    public void finish(Database.BatchableContext context) {
        String jobId = context == null || context.getJobId() == null ? null : String.valueOf(context.getJobId());
        String summary =
            'chunks: ' +
            chunkCount +
            ', processed: ' +
            processedCount +
            ', status changes: ' +
            statusChangeCount +
            ', first scores: ' +
            initialScoreCount +
            ', failures: ' +
            failureCount;

        if (failureCount > 0) {
            RIQ_Logger.warn('RIQ_NightlyScoreBatch', 'Nightly score finished with failures - ' + summary, jobId);
        } else {
            RIQ_Logger.info('RIQ_NightlyScoreBatch', 'Nightly score complete - ' + summary, jobId);
        }
    }

    /**
     * @description Batch size from RIQ_Batch_Config__mdt, so an admin can tune
     * the load without a deployment. Falls back to 200 when the record or the
     * field is missing, and clamps to the platform's 1..2000 range.
     * @return A batch size safe to pass to Database.executeBatch.
     */
    public static Integer resolveBatchSize() {
        List<RIQ_Batch_Config__mdt> configs = [SELECT Batch_Size__c FROM RIQ_Batch_Config__mdt LIMIT 1];

        if (configs.isEmpty() || configs[0].Batch_Size__c == null) {
            return DEFAULT_BATCH_SIZE;
        }

        Integer configured = configs[0].Batch_Size__c.intValue();

        if (configured < 1) {
            return DEFAULT_BATCH_SIZE;
        }

        return configured > 2000 ? 2000 : configured;
    }
}
