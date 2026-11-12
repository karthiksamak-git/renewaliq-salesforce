/**
 * @description Recalculates health scores for a set of Accounts in one
 * transaction: one query for accounts, one for signals, one cached metadata
 * read, then a single update and a single insert.
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
     * @description Queueable entry point.
     * @param context Queueable context supplied by the platform.
     */
    public void execute(QueueableContext context) {
        recalculate(accountIds);
    }

    /**
     * @description The recalculation itself. Public and static so it can be
     * called synchronously from admin scripts and tests, and so the queueable
     * stays a thin wrapper.
     * @param accountIds Accounts to re-score.
     */
    public static void recalculate(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) {
            return;
        }

        Map<String, RIQ_ScoringRule> rules = RIQ_ScoringRuleProvider.getRules();

        if (rules.isEmpty()) {
            // Scoring with no rules would set every account to 100, which is
            // worse than leaving the previous score in place.
            System.debug(LoggingLevel.ERROR, 'RenewalIQ: no active scoring rules found, skipping recalculation.');
            return;
        }

        List<Account> accounts = new RIQ_AccountSelector(AccessLevel.SYSTEM_MODE).getByIds(accountIds);

        if (accounts.isEmpty()) {
            return;
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

            RIQ_HealthScoreService.ScoreResult result = RIQ_HealthScoreService.calculate(
                signalsByAccount.get(account.Id),
                today,
                daysToRenewal,
                rules,
                thresholds
            );

            accountsToUpdate.add(
                new Account(
                    Id = account.Id,
                    RIQ_Health_Score__c = result.score,
                    RIQ_Health_Status__c = result.status,
                    RIQ_Churn_Probability__c = result.churnProbability,
                    RIQ_Last_Scored__c = calculatedOn
                )
            );

            historyToInsert.add(
                new RIQ_Score_History__c(
                    Account__c = account.Id,
                    Score__c = result.score,
                    Status__c = result.status,
                    Calculated_On__c = calculatedOn,
                    Drivers__c = result.driversJson
                )
            );
        }

        saveAccounts(accountsToUpdate);
        saveHistory(historyToInsert);
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
     */
    private static void saveAccounts(List<Account> accountsToUpdate) {
        if (accountsToUpdate.isEmpty()) {
            return;
        }

        List<Database.SaveResult> results = Database.update(accountsToUpdate, false, AccessLevel.SYSTEM_MODE);

        for (Database.SaveResult result : results) {
            if (!result.isSuccess()) {
                System.debug(LoggingLevel.ERROR, 'RenewalIQ: could not update score for ' + result.getId() + ' - ' + result.getErrors());
            }
        }
    }

    /**
     * @description Appends the audit trail. History is the reason a trend chart
     * can exist later, so it is written in the same transaction as the score.
     * @param historyToInsert One row per recalculated account.
     */
    private static void saveHistory(List<RIQ_Score_History__c> historyToInsert) {
        if (historyToInsert.isEmpty()) {
            return;
        }

        List<Database.SaveResult> results = Database.insert(historyToInsert, false, AccessLevel.SYSTEM_MODE);

        for (Database.SaveResult result : results) {
            if (!result.isSuccess()) {
                System.debug(LoggingLevel.ERROR, 'RenewalIQ: could not write score history - ' + result.getErrors());
            }
        }
    }
}
