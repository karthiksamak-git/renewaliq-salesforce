/**
 * @description Generates AI insights in the background, a few accounts at a time.
 *
 * Callouts cannot run inside the platform event trigger (it holds uncommitted
 * DML) and must not run inside a batch loop, so the playbook enqueues this job
 * instead. Each job is capped at MAX_ACCOUNTS_PER_JOB callouts and chains the
 * remainder: a job that tries to call the model 200 times would blow the 120
 * second async budget long before it finished, and the failure would be silent.
 */
public class RIQ_AiInsightQueueable implements Queueable, Database.AllowsCallouts {
    /**
     * Callouts per job. At the 30 second default timeout, three callouts are
     * 90 seconds worst case, which leaves headroom inside the 120 second
     * asynchronous limit for the queries and the update.
     */
    public static final Integer MAX_ACCOUNTS_PER_JOB = 3;

    /** Accounts still to process, in a stable order. */
    private final List<Id> accountIds;

    /**
     * @param accountIds Accounts to generate insights for.
     */
    public RIQ_AiInsightQueueable(Set<Id> accountIds) {
        this.accountIds = accountIds == null ? new List<Id>() : new List<Id>(accountIds);
        this.accountIds.sort();
    }

    /**
     * @description Processes up to MAX_ACCOUNTS_PER_JOB accounts, then chains a
     * new job for the rest. Reads with SYSTEM_MODE because it runs as the
     * subscriber or the enqueuing user, not as a CSM looking at a page.
     * @param context Queueable context.
     */
    public void execute(QueueableContext context) {
        if (accountIds.isEmpty()) {
            return;
        }

        RIQ_AiInsightService.Config config = RIQ_AiInsightService.loadConfig();

        if (!config.isEnabled) {
            // Respect the toggle in the background: generating rule-based text
            // for every at-risk account on every status change is noise. The
            // manual button still works, because the user asked for it. Nothing
            // is logged: a disabled feature is not an incident.
            return;
        }

        List<Id> batchIds = firstBatch(accountIds);
        List<Id> remainder = remainingBatch(accountIds);

        generateFor(batchIds);

        if (!remainder.isEmpty()) {
            try {
                System.enqueueJob(new RIQ_AiInsightQueueable(new Set<Id>(remainder)));
            } catch (Exception chainFailure) {
                // A refused chain only defers the rest: the next status change or
                // the next nightly run picks them up. It must not fail this job.
                RIQ_Logger.warn('RIQ_AiInsightQueueable', 'Could not chain the remaining insight jobs.', chainFailure);
            }
        }
    }

    /**
     * @param ids All accounts still to process, in order.
     * @return The accounts this job will handle.
     */
    @TestVisible
    private static List<Id> firstBatch(List<Id> ids) {
        List<Id> batch = new List<Id>();

        for (Integer i = 0; i < ids.size() && i < MAX_ACCOUNTS_PER_JOB; i++) {
            batch.add(ids[i]);
        }

        return batch;
    }

    /**
     * @param ids All accounts still to process, in order.
     * @return The accounts handed to the next job; empty when the work is done.
     */
    @TestVisible
    private static List<Id> remainingBatch(List<Id> ids) {
        List<Id> remainder = new List<Id>();

        for (Integer i = MAX_ACCOUNTS_PER_JOB; i < ids.size(); i++) {
            remainder.add(ids[i]);
        }

        return remainder;
    }

    /**
     * @description One query for the accounts, one for their signals and one for
     * the newest score history, then per-account generation and a single update.
     * @param ids Accounts in this job.
     */
    @TestVisible
    private void generateFor(List<Id> ids) {
        if (ids.isEmpty()) {
            return;
        }

        Set<Id> idSet = new Set<Id>(ids);
        List<Account> accounts = new RIQ_AccountSelector(AccessLevel.SYSTEM_MODE).getForAiInsight(idSet);

        if (accounts.isEmpty()) {
            return;
        }

        Map<Id, List<RIQ_Health_Signal__c>> signalsByAccount = groupSignals(
            new RIQ_HealthSignalSelector(AccessLevel.SYSTEM_MODE).getByAccountIds(idSet)
        );
        Map<Id, String> driversByAccount = newestDrivers(
            new RIQ_ScoreHistorySelector(AccessLevel.SYSTEM_MODE).getRecentForAccounts(idSet, ids.size())
        );

        List<Account> updates = new List<Account>();

        for (Account account : accounts) {
            try {
                RIQ_AiInsightService.Insight insight = RIQ_AiInsightService.generate(
                    account,
                    signalsByAccount.get(account.Id),
                    driversByAccount.get(account.Id)
                );

                // generate() is total: it always returns an insight, model or
                // rule based, so there is nothing to skip here.
                updates.add(
                    new Account(
                        Id = account.Id,
                        RIQ_AI_Summary__c = insight.summary,
                        RIQ_Next_Best_Action__c = insight.nextBestAction,
                        RIQ_AI_Risk_Reasons__c = String.join(insight.riskReasons, '\n'),
                        RIQ_AI_Source__c = insight.source,
                        RIQ_AI_Generated_On__c = insight.generatedOn
                    )
                );
            } catch (Exception failure) {
                // One bad account must not cost the rest of the job.
                RIQ_Logger.error(
                    'RIQ_AiInsightQueueable',
                    'Insight generation failed for one account.',
                    failure,
                    account.Id
                );
            }
        }

        try {
            Database.update(updates, AccessLevel.SYSTEM_MODE);
        } catch (DmlException dmlFailure) {
            RIQ_Logger.error('RIQ_AiInsightQueueable', 'Insight update failed.', dmlFailure);
        }
    }

    /**
     * @param signals Signals for several accounts, newest first.
     * @return Signals grouped by account.
     */
    private static Map<Id, List<RIQ_Health_Signal__c>> groupSignals(List<RIQ_Health_Signal__c> signals) {
        Map<Id, List<RIQ_Health_Signal__c>> byAccount = new Map<Id, List<RIQ_Health_Signal__c>>();

        for (RIQ_Health_Signal__c signal : signals) {
            if (!byAccount.containsKey(signal.Account__c)) {
                byAccount.put(signal.Account__c, new List<RIQ_Health_Signal__c>());
            }

            byAccount.get(signal.Account__c).add(signal);
        }

        return byAccount;
    }

    /**
     * @param history Recent history rows, newest first.
     * @return Drivers payload of the newest row per account.
     */
    private static Map<Id, String> newestDrivers(List<RIQ_Score_History__c> history) {
        Map<Id, String> driversByAccount = new Map<Id, String>();

        for (RIQ_Score_History__c row : history) {
            if (!driversByAccount.containsKey(row.Account__c)) {
                driversByAccount.put(row.Account__c, row.Drivers__c);
            }
        }

        return driversByAccount;
    }
}
