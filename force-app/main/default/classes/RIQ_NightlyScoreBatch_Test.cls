/**
 * @description Nightly batch behaviour: scope, bulk scoring through the shared
 * process(), stateful counters across chunks, the empty-scope no-op and the
 * Custom Metadata batch size.
 */
@IsTest
private class RIQ_NightlyScoreBatch_Test {
    /**
     * @param accounts Accounts to attach signals to.
     */
    private static void createSignals(List<Account> accounts) {
        RIQ_TriggerHandler.bypass('RIQ_HealthSignalTriggerHandler');
        insert RIQ_TestDataFactory.buildSignalsForAccounts(
            accounts,
            RIQ_TestDataFactory.LOW_PRODUCT_USAGE,
            2,
            Date.today()
        );
        RIQ_TriggerHandler.clearBypass();
    }

    @IsTest
    static void batchScoresTwoHundredPlusAccountsInChunks() {
        List<Account> accounts = RIQ_TestDataFactory.createAccounts(201);
        createSignals(accounts);

        Test.startTest();
        // A test method may only run one executeBatch, so the chunk size is set
        // above the scope: 201 accounts execute once, as one chunk.
        Id jobId = Database.executeBatch(new RIQ_NightlyScoreBatch(), 500);
        Test.stopTest();

        System.assertNotEquals(null, jobId);

        List<Account> scored = [
            SELECT RIQ_Health_Score__c, RIQ_Health_Status__c, RIQ_Last_Scored__c
            FROM Account
            WHERE Id IN :accounts
        ];

        System.assertEquals(201, scored.size());

        for (Account account : scored) {
            System.assertEquals(70, account.RIQ_Health_Score__c.intValue(), '15 * 2 = 30 points removed.');
            System.assertEquals('Watch', account.RIQ_Health_Status__c);
            System.assertNotEquals(null, account.RIQ_Last_Scored__c);
        }

        System.assertEquals(201, [SELECT COUNT() FROM RIQ_Score_History__c], 'One history row per account.');
    }

    @IsTest
    static void statefulCountersAggregateAcrossChunks() {
        List<Account> accounts = RIQ_TestDataFactory.createAccounts(3);
        createSignals(accounts);

        RIQ_NightlyScoreBatch batch = new RIQ_NightlyScoreBatch();

        Test.startTest();
        Database.QueryLocator locator = batch.start(null);
        batch.execute(null, new List<SObject>{ accounts[0], accounts[1] });
        batch.execute(null, new List<SObject>{ accounts[2] });
        batch.finish(null);
        Test.stopTest();

        System.assertNotEquals(null, locator);
        System.assertEquals(2, batch.chunkCount);
        System.assertEquals(3, batch.processedCount);
        System.assertEquals(3, batch.initialScoreCount, 'All three were scored for the first time.');
        System.assertEquals(0, batch.statusChangeCount, 'A first score is a baseline, not a transition.');
        System.assertEquals(0, batch.failureCount);
        System.assertEquals(3, [SELECT COUNT() FROM RIQ_Score_History__c]);
    }

    @IsTest
    static void emptyScopeIsANoOp() {
        RIQ_NightlyScoreBatch batch = new RIQ_NightlyScoreBatch();

        Test.startTest();
        batch.execute(null, new List<SObject>());
        batch.finish(null);
        Test.stopTest();

        System.assertEquals(0, batch.processedCount);
        System.assertEquals(0, batch.failureCount);
        System.assertEquals(0, [SELECT COUNT() FROM RIQ_Score_History__c]);
    }

    @IsTest
    static void accountsWithoutArrOrSignalsStayOutOfScope() {
        insert new List<Account>{ new Account(Name = 'RenewalIQ Prospect ' + DateTime.now().getTime()) };

        Test.startTest();
        Database.executeBatch(new RIQ_NightlyScoreBatch(), 200);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM RIQ_Score_History__c], 'Prospects are not scored.');
    }

    @IsTest
    static void batchSizeComesFromCustomMetadata() {
        System.assertEquals(200, RIQ_NightlyScoreBatch.resolveBatchSize());
        System.assertEquals(200, RIQ_NightlyScoreBatch.DEFAULT_BATCH_SIZE);
    }
}
