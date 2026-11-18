/**
 * @description The load test the design claims: 200 accounts with 15 signals
 * each, scored in one chunk, measured against documented governor thresholds.
 *
 * The thresholds are deliberately tighter than the platform limits. A chunk
 * that uses 10% of the query budget has room to grow; one that uses 90% is one
 * extra feature away from failing in production, where the failure would be a
 * half-scored book of business rather than a red test.
 *
 * The signal trigger is bypassed while the fixture is inserted. That is not to
 * hide work: the measurement is the recalculation, and letting 3,000 inserts
 * enqueue a queueable first would measure the fixture instead.
 */
@IsTest
private class RIQ_Performance_Test {
    /** Accounts in one simulated batch chunk. */
    private static final Integer ACCOUNT_COUNT = 200;
    /** Signals per account. */
    private static final Integer SIGNALS_PER_ACCOUNT = 15;
    /** Documented ceiling on SOQL statements for one chunk. */
    private static final Integer MAX_QUERIES = 10;
    /** Documented ceiling on DML statements for one chunk. */
    private static final Integer MAX_DML_STATEMENTS = 4;
    /** Documented ceiling on CPU milliseconds for one chunk. */
    private static final Long MAX_CPU_MS = 10000;

    /**
     * @return Accounts and signals for one chunk, already inserted.
     */
    private static List<Account> createBook() {
        List<Account> accounts = new List<Account>();
        String uniqueSuffix = String.valueOf(DateTime.now().getTime());

        for (Integer i = 0; i < ACCOUNT_COUNT; i++) {
            accounts.add(
                new Account(
                    Name = 'RIQ Perf ' + uniqueSuffix + '-' + i,
                    RIQ_ARR__c = 200000 + (i * 1000),
                    RIQ_Contract_End_Date__c = Date.today().addDays(Math.mod(i, 400) - 30)
                )
            );
        }

        insert accounts;

        List<RIQ_Health_Signal__c> signals = new List<RIQ_Health_Signal__c>();
        List<String> types = new List<String>{
            'Support Escalation',
            'Low Product Usage',
            'Missed QBR',
            'Late Payment',
            'Executive Sponsor Left'
        };

        for (Integer a = 0; a < accounts.size(); a++) {
            for (Integer s = 0; s < SIGNALS_PER_ACCOUNT; s++) {
                signals.add(
                    new RIQ_Health_Signal__c(
                        Account__c = accounts[a].Id,
                        Signal_Type__c = types[Math.mod(a + s, types.size())],
                        Severity__c = 1 + Math.mod(a + s, 5),
                        Occurred_On__c = Date.today().addDays(-Math.mod(a * 3 + s, 120))
                    )
                );
            }
        }

        RIQ_TriggerHandler.bypass('RIQ_HealthSignalTriggerHandler');
        insert signals;
        RIQ_TriggerHandler.clearBypass();

        return accounts;
    }

    @IsTest
    static void oneChunkOfTwoHundredAccountsStaysInsideTheDocumentedBudget() {
        List<Account> accounts = createBook();
        Set<Id> accountIds = new Map<Id, Account>(accounts).keySet();

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        Long cpuBefore = Limits.getCpuTime();

        RIQ_HealthScoreRecalculator.ProcessResult result = RIQ_HealthScoreRecalculator.process(accountIds);

        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Long cpuUsed = Limits.getCpuTime() - cpuBefore;
        Test.stopTest();

        System.debug( // NOPMD AvoidDebugStatements: this line is the measurement report.
            'RIQ_PERF recalc accounts=' +
                ACCOUNT_COUNT +
                ' signals=' +
                (ACCOUNT_COUNT * SIGNALS_PER_ACCOUNT) +
                ' queries=' +
                queriesUsed +
                ' dml=' +
                dmlUsed +
                ' cpuMs=' +
                cpuUsed
        );

        Assert.areEqual(ACCOUNT_COUNT, result.processedCount, 'Every account in the chunk should be scored.');
        Assert.areEqual(ACCOUNT_COUNT, result.updatedCount, 'Every score should save.');
        Assert.areEqual(0, result.failureCount, 'A clean run should record no failures.');
        Assert.isTrue(queriesUsed <= MAX_QUERIES, 'SOQL statements used: ' + queriesUsed + ' (budget ' + MAX_QUERIES + ').');
        Assert.isTrue(dmlUsed <= MAX_DML_STATEMENTS, 'DML statements used: ' + dmlUsed + ' (budget ' + MAX_DML_STATEMENTS + ').');
        Assert.isTrue(cpuUsed < MAX_CPU_MS, 'CPU milliseconds used: ' + cpuUsed + ' (budget ' + MAX_CPU_MS + ').');
        Assert.areEqual(
            ACCOUNT_COUNT,
            [SELECT COUNT() FROM RIQ_Score_History__c],
            'One history row per account keeps the trend chart honest.'
        );
    }

    @IsTest
    static void theNightlyBatchScoresTwoHundredAccountsInOneChunk() {
        createBook();

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Id jobId = Database.executeBatch(new RIQ_NightlyScoreBatch(), ACCOUNT_COUNT);
        Test.stopTest();

        System.debug( // NOPMD AvoidDebugStatements: the observed batch numbers are the report.
            'RIQ_PERF batch accounts=' +
                ACCOUNT_COUNT +
                ' job=' +
                String.valueOf(jobId) +
                ' queriesFromTest=' +
                (Limits.getQueries() - queriesBefore)
        );

        Assert.areEqual(ACCOUNT_COUNT, [SELECT COUNT() FROM Account WHERE RIQ_Last_Scored__c != NULL], 'The batch should score the whole chunk.');
        Assert.areEqual(
            ACCOUNT_COUNT,
            [SELECT COUNT() FROM RIQ_Score_History__c],
            'Each scored account should get one history row per run.'
        );
    }
}
