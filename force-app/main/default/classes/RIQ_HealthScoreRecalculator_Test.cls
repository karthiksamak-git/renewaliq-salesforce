/**
 * @description Queueable behaviour: bulk recalculation, the no-op guards, churn
 * from renewal dates, and the audit row written with every score.
 */
@IsTest
private class RIQ_HealthScoreRecalculator_Test {
    /**
     * @param accounts Accounts to score.
     * @param signalType Picklist value.
     * @param severity Severity 1..5.
     * @param daysAgo How far in the past the signal occurred.
     */
    private static void createSignals(List<Account> accounts, String signalType, Integer severity, Integer daysAgo) {
        RIQ_TriggerHandler.bypass('RIQ_HealthSignalTriggerHandler');
        insert RIQ_TestDataFactory.buildSignalsForAccounts(
            accounts,
            signalType,
            severity,
            Date.today().addDays(-daysAgo)
        );
        RIQ_TriggerHandler.clearBypass();
    }

    @IsTest
    static void queueableScoresEveryAccountInBulk() {
        List<Account> accounts = RIQ_TestDataFactory.createAccounts(200);
        createSignals(accounts, RIQ_TestDataFactory.LOW_PRODUCT_USAGE, 2, 0);

        Test.startTest();
        System.enqueueJob(new RIQ_HealthScoreRecalculator(new Map<Id, Account>(accounts).keySet()));
        Test.stopTest();

        List<Account> scored = [
            SELECT RIQ_Health_Score__c, RIQ_Health_Status__c, RIQ_Churn_Probability__c
            FROM Account
            WHERE Id IN :accounts
        ];

        System.assertEquals(200, scored.size());
        System.assertEquals(200, [SELECT COUNT() FROM RIQ_Score_History__c]);

        for (Account account : scored) {
            System.assertEquals(70, account.RIQ_Health_Score__c.intValue(), '15 * 2 = 30 points removed.');
            System.assertEquals('Watch', account.RIQ_Health_Status__c);
            System.assertNotEquals(null, account.RIQ_Churn_Probability__c);
        }
    }

    @IsTest
    static void accountWithoutSignalsScoresPerfect() {
        List<Account> singleAccount = RIQ_TestDataFactory.createAccounts(1);
        Account account = singleAccount[0];

        Test.startTest();
        RIQ_HealthScoreRecalculator.recalculate(new Set<Id>{ account.Id });
        Test.stopTest();

        Account scored = [SELECT RIQ_Health_Score__c, RIQ_Health_Status__c FROM Account WHERE Id = :account.Id];
        System.assertEquals(100, scored.RIQ_Health_Score__c.intValue());
        System.assertEquals('Healthy', scored.RIQ_Health_Status__c);
    }

    @IsTest
    static void churnRisesWhenRenewalIsClose() {
        List<Account> singleAccount = RIQ_TestDataFactory.createAccounts(1);
        Account account = singleAccount[0];
        account.RIQ_Contract_End_Date__c = Date.today().addDays(10);
        update account;
        createSignals(new List<Account>{ account }, RIQ_TestDataFactory.SUPPORT_ESCALATION, 2, 0);

        Test.startTest();
        RIQ_HealthScoreRecalculator.recalculate(new Set<Id>{ account.Id });
        Test.stopTest();

        Account scored = [SELECT RIQ_Health_Score__c, RIQ_Churn_Probability__c FROM Account WHERE Id = :account.Id];
        System.assertEquals(50, scored.RIQ_Health_Score__c.intValue(), '25 * 2 = 50 points removed.');
        System.assertEquals(
            57,
            scored.RIQ_Churn_Probability__c.intValue(),
            '50 * 0.9 = 45, plus 12 for a renewal in 10 days.'
        );
    }

    @IsTest
    static void historyCapturesTheDriverBreakdown() {
        List<Account> singleAccount = RIQ_TestDataFactory.createAccounts(1);
        Account account = singleAccount[0];
        createSignals(new List<Account>{ account }, RIQ_TestDataFactory.SUPPORT_ESCALATION, 3, 0);

        Test.startTest();
        RIQ_HealthScoreRecalculator.recalculate(new Set<Id>{ account.Id });
        Test.stopTest();

        RIQ_Score_History__c history = [
            SELECT Score__c, Status__c, Calculated_On__c, Drivers__c
            FROM RIQ_Score_History__c
            WHERE Account__c = :account.Id
        ];

        System.assertEquals(25, history.Score__c.intValue());
        System.assertEquals('Critical', history.Status__c);
        System.assertNotEquals(null, history.Calculated_On__c);
        System.assert(history.Drivers__c.contains('Support Escalation'), 'The CSM can see why the score moved.');
    }

    @IsTest
    static void recalculationIsRepeatable() {
        List<Account> singleAccount = RIQ_TestDataFactory.createAccounts(1);
        Account account = singleAccount[0];
        createSignals(new List<Account>{ account }, RIQ_TestDataFactory.POSITIVE_EXPANSION, 1, 0);

        Test.startTest();
        RIQ_HealthScoreRecalculator.recalculate(new Set<Id>{ account.Id });
        RIQ_HealthScoreRecalculator.recalculate(new Set<Id>{ account.Id });
        Test.stopTest();

        Account scored = [SELECT RIQ_Health_Score__c FROM Account WHERE Id = :account.Id];
        System.assertEquals(100, scored.RIQ_Health_Score__c.intValue(), 'A credit cannot exceed a perfect score.');
        System.assertEquals(2, [SELECT COUNT() FROM RIQ_Score_History__c], 'Both runs are audited.');
    }

    @IsTest
    static void emptyAndNullInputsAreNoOps() {
        Test.startTest();
        RIQ_HealthScoreRecalculator.recalculate(new Set<Id>());
        RIQ_HealthScoreRecalculator.recalculate(null);
        new RIQ_HealthScoreRecalculator(null).execute(null);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM RIQ_Score_History__c]);
    }

    @IsTest
    static void accountThatIsGoneIsSkipped() {
        List<Account> accounts = RIQ_TestDataFactory.createAccounts(2);
        Account scoredAccount = accounts[0];
        Id removedAccountId = accounts[1].Id;
        delete accounts[1];
        createSignals(new List<Account>{ scoredAccount }, RIQ_TestDataFactory.MISSED_QBR, 2, 0);
        Set<Id> ids = new Set<Id>{ scoredAccount.Id, removedAccountId };

        Test.startTest();
        RIQ_HealthScoreRecalculator.recalculate(ids);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM RIQ_Score_History__c], 'Only existing accounts produce history.');
        Account rescored = [SELECT RIQ_Health_Score__c FROM Account WHERE Id = :scoredAccount.Id];
        System.assertEquals(80, rescored.RIQ_Health_Score__c.intValue(), '10 * 2 = 20 points removed.');
    }

    @IsTest
    static void noActiveRulesLeavesTheLastScoreAlone() {
        // The dangerous failure mode: scoring with zero rules subtracts nothing and
        // writes 100 to every account, wiping a real book of business in one night.
        // An admin who deactivates every rule must get "skipped", not "perfect".
        List<Account> singleAccount = RIQ_TestDataFactory.createAccounts(1);
        Account account = singleAccount[0];
        account.RIQ_Health_Score__c = 42;
        account.RIQ_Health_Status__c = 'At Risk';
        update account;

        Test.startTest();
        RIQ_HealthScoreRecalculator.ProcessResult result = RIQ_HealthScoreRecalculator.process(
            new Set<Id>{ account.Id },
            new Map<String, RIQ_ScoringRule>(),
            RIQ_TestDataFactory.testThresholds()
        );
        Test.stopTest();

        Account untouched = [SELECT RIQ_Health_Score__c, RIQ_Health_Status__c FROM Account WHERE Id = :account.Id];
        System.assertEquals(42, untouched.RIQ_Health_Score__c.intValue(), 'The previous score is kept.');
        System.assertEquals('At Risk', untouched.RIQ_Health_Status__c);
        System.assertEquals(0, result.processedCount, 'Nothing was scored.');
        System.assertEquals(0, result.updatedCount);
        System.assertEquals(0, [SELECT COUNT() FROM RIQ_Score_History__c], 'A skipped run writes no audit row.');
    }

    @IsTest
    static void oneHundredFiftyBandChangesPublishInTwoChunks() {
        // The publish cap is per call, so the recalculator batches events in
        // hundreds. 150 transitions prove both the full chunk and the tail chunk
        // are published - a dropped chunk is a renewal nobody picks up.
        List<Account> accounts = RIQ_TestDataFactory.createAccounts(150);

        for (Account account : accounts) {
            account.RIQ_Health_Score__c = 92;
            account.RIQ_Health_Status__c = 'Healthy';
        }

        update accounts;

        RIQ_TriggerHandler.bypass('RIQ_HealthSignalTriggerHandler');
        insert RIQ_TestDataFactory.buildSignalsForAccounts(
            accounts,
            RIQ_TestDataFactory.LOW_PRODUCT_USAGE,
            2,
            Date.today()
        );
        RIQ_TriggerHandler.clearBypass();

        Test.startTest();
        RIQ_HealthScoreRecalculator.ProcessResult result = RIQ_HealthScoreRecalculator.process(
            new Map<Id, Account>(accounts).keySet()
        );
        Test.stopTest();

        System.assertEquals(150, result.processedCount);
        System.assertEquals(150, result.statusChangeCount, 'Every account moved from Healthy to Watch.');
        System.assertEquals(0, result.eventFailureCount, 'Both the 100-event chunk and the 50-event tail landed.');
        System.assertEquals(0, result.failureCount);
        System.assertEquals(150, result.historyCount);
    }

    @IsTest
    static void aBandThatDoesNotMatchTheHistoryPicklistIsCountedAsAFailure() {
        // A band renamed in Custom Metadata without matching the picklist is a
        // configuration mistake. It must be logged and counted, and it must not
        // stop the other accounts in the same chunk from being scored.
        List<Account> accounts = RIQ_TestDataFactory.createAccounts(2);
        RIQ_TriggerHandler.bypass('RIQ_HealthSignalTriggerHandler');
        insert RIQ_TestDataFactory.buildSignalsForAccounts(
            accounts,
            RIQ_TestDataFactory.SUPPORT_ESCALATION,
            2,
            Date.today()
        );
        RIQ_TriggerHandler.clearBypass();

        List<RIQ_HealthThreshold> misconfigured = new List<RIQ_HealthThreshold>{
            new RIQ_HealthThreshold('Legacy Band', 0)
        };

        Test.startTest();
        RIQ_HealthScoreRecalculator.ProcessResult result = RIQ_HealthScoreRecalculator.process(
            new Map<Id, Account>(accounts).keySet(),
            RIQ_TestDataFactory.testRules(),
            misconfigured
        );
        Test.stopTest();

        System.assertEquals(2, result.processedCount, 'Both accounts were still scored.');
        System.assertEquals(0, result.historyCount, 'The history picklist rejects an unknown band.');
        System.assert(result.failureCount >= 1, 'The rejected history row is counted, never thrown.');
    }
}
