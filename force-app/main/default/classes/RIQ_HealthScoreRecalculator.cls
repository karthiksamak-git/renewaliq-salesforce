/**
 * @description Recalculates health scores for a set of Accounts in one
 * transaction: one query for accounts, one for signals, one cached metadata
 * read, then a single update and a single insert.
 *
 * Since Phase 3 this class is a thin async wrapper around process(), the one
 * code path shared by the health-signal trigger's Queueable, the nightly batch
 * and any synchronous admin script. Keeping a single implementation is what
 * makes "the nightly number" and "the number you see after logging a signal"
 * provably identical.
 *
 * Runs without sharing and with SYSTEM_MODE DML on purpose. The score fields are
 * system-maintained - RIQ_CSM can read them but not edit them - so writing them
 * under the triggering user's permissions would silently fail for exactly the
 * people most likely to create a signal. The ids handed in come from records
 * that user just touched, so this is not a privilege escalation.
 */
public without sharing class RIQ_HealthScoreRecalculator implements Queueable {
    private final Set<Id> accountIds;

    /**
     * @param accountIds Accounts to re-score. Copied defensively so the caller
     *        cannot mutate the set while the job is queued.
     */
    public RIQ_HealthScoreRecalculator(Set<Id> accountIds) {
        this.accountIds = accountIds == null ? new Set<Id>() : new Set<Id>(accountIds);
    }

    /**
     * @description Queueable entry point. Delegates to process() so a queued job
     * and a batch chunk behave identically.
     * @param context Queueable context supplied by the platform.
     */
    public void execute(QueueableContext context) {
        process(accountIds);
    }

    /**
     * @description Backwards-compatible void entry point used by Phase 2 callers
     * and admin scripts. New code should call process() to get the counts.
     * @param accountIds Accounts to re-score.
     */
    public static void recalculate(Set<Id> accountIds) {
        process(accountIds);
    }

    /**
     * @description The recalculation itself. Synchronous and bulk-safe: one
     * account query, one signal query, one account update, one history insert,
     * and one platform event publish, regardless of how many accounts came in.
     *
     * @param accountIds Accounts to re-score.
     * @return Counts for the caller (batch, schedulable, test) plus the list of
     *         real status transitions that were published as platform events.
     */
    public static ProcessResult process(Set<Id> accountIds) {
        ProcessResult result = new ProcessResult();

        if (accountIds == null || accountIds.isEmpty()) {
            return result;
        }

        Map<String, RIQ_ScoringRule> rules = RIQ_ScoringRuleProvider.getRules();

        if (rules.isEmpty()) {
            // Scoring with no rules would set every account to 100, which is
            // worse than leaving the previous score in place.
            RIQ_Logger.error('RIQ_HealthScoreRecalculator', 'No active scoring rules were found, so recalculation was skipped.');
            return result;
        }

        List<Account> accounts = new RIQ_AccountSelector(AccessLevel.SYSTEM_MODE).getByIds(accountIds);

        if (accounts.isEmpty()) {
            return result;
        }

        Set<Id> foundAccountIds = new Map<Id, Account>(accounts).keySet();
        List<RIQ_Health_Signal__c> signals = new RIQ_HealthSignalSelector(AccessLevel.SYSTEM_MODE)
            .getByAccountIds(foundAccountIds);
        Map<Id, List<RIQ_Health_Signal__c>> signalsByAccount = groupByAccount(signals);
        List<RIQ_HealthThreshold> thresholds = RIQ_ScoringRuleProvider.getThresholds();
        Date today = Date.today();
        DateTime calculatedOn = DateTime.now();

        List<Account> accountsToUpdate = new List<Account>();
        List<RIQ_Score_History__c> historyToInsert = new List<RIQ_Score_History__c>();

        for (Account account : accounts) {
            Integer daysToRenewal = account.RIQ_Contract_End_Date__c == null
                ? null
                : today.daysBetween(account.RIQ_Contract_End_Date__c);

            RIQ_HealthScoreService.ScoreResult scoreResult = RIQ_HealthScoreService.calculate(
                signalsByAccount.get(account.Id),
                today,
                daysToRenewal,
                rules,
                thresholds
            );

            accountsToUpdate.add(
                new Account(
                    Id = account.Id,
                    RIQ_Health_Score__c = scoreResult.score,
                    RIQ_Health_Status__c = scoreResult.status,
                    RIQ_Churn_Probability__c = scoreResult.churnProbability,
                    RIQ_Last_Scored__c = calculatedOn
                )
            );

            historyToInsert.add(
                new RIQ_Score_History__c(
                    Account__c = account.Id,
                    Score__c = scoreResult.score,
                    Status__c = scoreResult.status,
                    Calculated_On__c = calculatedOn,
                    Drivers__c = scoreResult.driversJson
                )
            );

            result.processedCount++;

            if (account.RIQ_Health_Status__c == null) {
                // DECISION: a first score (null -> X) is a baseline, not a
                // transition, so it publishes nothing. Otherwise the first run
                // against a newly loaded book of accounts would fire one
                // playbook per account and bury CSMs in duplicate outreach
                // tasks for customers nobody has judged yet.
                result.initialScoreCount++;
            } else if (scoreResult.status != null && account.RIQ_Health_Status__c != scoreResult.status) {
                result.statusChanges.add(
                    new StatusChange(account.Id, account.RIQ_Health_Status__c, scoreResult.status, scoreResult.score)
                );
            }
        }

        result.updatedCount = saveAccounts(accountsToUpdate);
        result.historyCount = saveHistory(historyToInsert);
        result.failureCount +=
            (accountsToUpdate.size() - result.updatedCount) + (historyToInsert.size() - result.historyCount);

        result.statusChangeCount = result.statusChanges.size();
        result.eventFailureCount = publishStatusChanges(result.statusChanges);
        result.failureCount += result.eventFailureCount;

        return result;
    }

    /**
     * @description Publishes one RIQ_Health_Status_Change__e per real transition.
     * The event is the domain signal ("this account's band moved"), so it is
     * published for every transition; deciding which transitions deserve a
     * playbook is the subscriber's job, not the scorer's.
     *
     * Events are published in chunks of 100 to stay well inside the per-call
     * publish cap, and every SaveResult is inspected - a silently dropped event
     * is a missed renewal, so a failure is counted for the caller.
     *
     * @param changes Transitions detected in this transaction.
     * @return Number of events that failed to publish.
     */
    private static Integer publishStatusChanges(List<StatusChange> changes) {
        if (changes.isEmpty()) {
            return 0;
        }

        Integer failures = 0;
        List<RIQ_Health_Status_Change__e> chunk = new List<RIQ_Health_Status_Change__e>();

        for (StatusChange change : changes) {
            chunk.add(
                new RIQ_Health_Status_Change__e(
                    AccountId__c = String.valueOf(change.accountId),
                    OldStatus__c = change.oldStatus,
                    NewStatus__c = change.newStatus,
                    Score__c = change.score
                )
            );

            if (chunk.size() == 100) {
                failures += publishChunk(chunk);
                chunk.clear();
            }
        }

        if (!chunk.isEmpty()) {
            failures += publishChunk(chunk);
        }

        return failures;
    }

    /**
     * @param events Events to publish.
     * @return Number of events that failed to publish.
     */
    private static Integer publishChunk(List<RIQ_Health_Status_Change__e> events) {
        Integer failures = 0;
        List<Database.SaveResult> results = EventBus.publish(events);

        for (Database.SaveResult saveResult : results) {
            if (!saveResult.isSuccess()) {
                failures++;
                RIQ_Logger.error('RIQ_HealthScoreRecalculator', 'Could not publish a health status change event: ' + saveResult.getErrors());
            }
        }

        return failures;
    }

    /**
     * @description Groups signals in memory so the engine never queries per
     * account. Accounts with no signals simply have no map entry.
     * @param signals Signals for every account in the job.
     * @return Signals keyed by Account id.
     */
    private static Map<Id, List<RIQ_Health_Signal__c>> groupByAccount(List<RIQ_Health_Signal__c> signals) {
        Map<Id, List<RIQ_Health_Signal__c>> grouped = new Map<Id, List<RIQ_Health_Signal__c>>();

        for (RIQ_Health_Signal__c signal : signals) {
            if (!grouped.containsKey(signal.Account__c)) {
                grouped.put(signal.Account__c, new List<RIQ_Health_Signal__c>());
            }

            grouped.get(signal.Account__c).add(signal);
        }

        return grouped;
    }

    /**
     * @description Saves scores without letting one bad record abort the job.
     * @param accountsToUpdate Accounts carrying the recalculated fields.
     * @return Number of accounts that saved successfully.
     */
    private static Integer saveAccounts(List<Account> accountsToUpdate) {
        if (accountsToUpdate.isEmpty()) {
            return 0;
        }

        Integer saved = 0;
        List<Database.SaveResult> results = Database.update(accountsToUpdate, false, AccessLevel.SYSTEM_MODE);

        for (Database.SaveResult result : results) {
            if (result.isSuccess()) {
                saved++;
            } else {
                RIQ_Logger.error('RIQ_HealthScoreRecalculator', 'Could not update a score.', null, String.valueOf(result.getId()));
            }
        }

        return saved;
    }

    /**
     * @description Appends the audit trail. History is the reason a trend chart
     * can exist later, so it is written in the same transaction as the score.
     * @param historyToInsert One row per recalculated account.
     * @return Number of history rows that saved successfully.
     */
    private static Integer saveHistory(List<RIQ_Score_History__c> historyToInsert) {
        if (historyToInsert.isEmpty()) {
            return 0;
        }

        Integer saved = 0;
        List<Database.SaveResult> results = Database.insert(historyToInsert, false, AccessLevel.SYSTEM_MODE);

        for (Database.SaveResult result : results) {
            if (result.isSuccess()) {
                saved++;
            } else {
                RIQ_Logger.error('RIQ_HealthScoreRecalculator', 'Could not write score history.', null, String.valueOf(result.getId()));
            }
        }

        return saved;
    }

    /**
     * @description One real band transition, ready to become an event.
     */
    public class StatusChange {
        /** Account that moved. */
        public Id accountId { get; private set; }
        /** Band before this recalculation. */
        public String oldStatus { get; private set; }
        /** Band after this recalculation. */
        public String newStatus { get; private set; }
        /** Score that produced the new band. */
        public Integer score { get; private set; }

        public StatusChange(Id accountId, String oldStatus, String newStatus, Integer score) {
            this.accountId = accountId;
            this.oldStatus = oldStatus;
            this.newStatus = newStatus;
            this.score = score;
        }
    }

    /**
     * @description What one process() call did. The batch makes these per-chunk
     * counts stateful so finish() can log the whole run in one line.
     */
    public class ProcessResult {
        /** Accounts loaded and scored. */
        public Integer processedCount = 0;
        /** Account updates that saved. */
        public Integer updatedCount = 0;
        /** RIQ_Score_History__c rows that saved. */
        public Integer historyCount = 0;
        /** Accounts scored for the first time (baseline, publishes no event). */
        public Integer initialScoreCount = 0;
        /** Real band transitions detected. */
        public Integer statusChangeCount = 0;
        /** Updates, history rows and events that failed. */
        public Integer failureCount = 0;
        /** Events that failed to publish. */
        public Integer eventFailureCount = 0;
        /** The transitions, in account order. */
        public List<StatusChange> statusChanges = new List<StatusChange>();
    }
}
