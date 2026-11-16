@IsTest
private class RIQ_AiInsightQueueable_Test {
    /**
     * @param enabled Whether the feature switch is on.
     * @return Configuration for the job.
     */
    private static RIQ_AiInsightService.Config config(Boolean enabled) {
        RIQ_AiInsightService.Config config = new RIQ_AiInsightService.Config();
        config.isEnabled = enabled;
        config.timeoutSeconds = 10;
        return config;
    }

    /**
     * @param count Accounts to create.
     * @return Inserted accounts with a risky band.
     */
    private static List<Account> riskyAccounts(Integer count) {
        List<Account> accounts = new List<Account>();

        for (Integer i = 0; i < count; i++) {
            accounts.add(
                new Account(
                    Name = 'RIQ Queueable ' + DateTime.now().getTime() + '-' + i,
                    RIQ_ARR__c = 90000 + i,
                    RIQ_Contract_End_Date__c = Date.today().addDays(30),
                    RIQ_Health_Score__c = 35,
                    RIQ_Health_Status__c = 'At Risk'
                )
            );
        }

        insert accounts;
        return accounts;
    }

    @IsTest
    static void generatesInsightsForTheBatch() {
        List<Account> accounts = riskyAccounts(2);
        insert new RIQ_Health_Signal__c(
            Account__c = accounts[0].Id,
            Signal_Type__c = RIQ_TestDataFactory.SUPPORT_ESCALATION,
            Severity__c = 4,
            Occurred_On__c = Date.today().addDays(-2)
        );
        RIQ_AiInsightService.configOverride = config(true);
        Test.setMock(HttpCalloutMock.class, new RIQ_CalloutMocks.Recorder());

        Test.startTest();
        System.enqueueJob(new RIQ_AiInsightQueueable(new Map<Id, Account>(accounts).keySet()));
        Test.stopTest();

        List<Account> updated = [
            SELECT RIQ_AI_Summary__c, RIQ_AI_Source__c, RIQ_AI_Generated_On__c
            FROM Account
            WHERE Id IN :accounts
        ];

        System.assertEquals(2, updated.size());

        for (Account account : updated) {
            System.assertEquals('Usage is down and the sponsor left.', account.RIQ_AI_Summary__c);
            System.assertEquals(RIQ_AiInsightService.SOURCE_AI, account.RIQ_AI_Source__c);
            System.assertNotEquals(null, account.RIQ_AI_Generated_On__c);
        }
    }

    @IsTest
    static void disabledToggleWritesNothing() {
        List<Account> accounts = riskyAccounts(1);
        RIQ_AiInsightService.configOverride = config(false);
        RIQ_CalloutMocks.Recorder recorder = new RIQ_CalloutMocks.Recorder();
        Test.setMock(HttpCalloutMock.class, recorder);

        Test.startTest();
        System.enqueueJob(new RIQ_AiInsightQueueable(new Map<Id, Account>(accounts).keySet()));
        Test.stopTest();

        Account untouched = [SELECT RIQ_AI_Summary__c FROM Account WHERE Id = :accounts[0].Id];
        System.assertEquals(null, untouched.RIQ_AI_Summary__c);
        System.assertEquals(0, recorder.callCount, 'Background generation honours the switch.');
    }

    @IsTest
    static void theWorkIsSplitIntoABatchAndARemainder() {
        List<Id> ids = new List<Id>();

        for (Account account : riskyAccounts(5)) {
            ids.add(account.Id);
        }

        List<Id> batch = RIQ_AiInsightQueueable.firstBatch(ids);
        List<Id> remainder = RIQ_AiInsightQueueable.remainingBatch(ids);

        System.assertEquals(RIQ_AiInsightQueueable.MAX_ACCOUNTS_PER_JOB, batch.size(), 'The cap is what bounds a job.');
        System.assertEquals(ids.size() - batch.size(), remainder.size(), 'Everything else is chained.');
        System.assertEquals(0, RIQ_AiInsightQueueable.remainingBatch(batch).size(), 'A page-sized job chains nothing.');
        System.assertEquals(0, RIQ_AiInsightQueueable.firstBatch(new List<Id>()).size());
    }

    @IsTest
    static void aLargeBatchStillProducesInsights() {
        List<Account> accounts = riskyAccounts(4);
        RIQ_AiInsightService.configOverride = config(true);
        Test.setMock(HttpCalloutMock.class, new RIQ_CalloutMocks.Recorder());

        Test.startTest();
        System.enqueueJob(new RIQ_AiInsightQueueable(new Map<Id, Account>(accounts).keySet()));
        Test.stopTest();

        // A LongTextArea cannot be filtered in SOQL, so the count is done in Apex.
        Integer withSummary = 0;

        for (Account account : [SELECT RIQ_AI_Summary__c FROM Account WHERE Id IN :accounts]) {
            if (String.isNotBlank(account.RIQ_AI_Summary__c)) {
                withSummary++;
            }
        }

        System.assert(
            withSummary >= RIQ_AiInsightQueueable.MAX_ACCOUNTS_PER_JOB,
            'At least one batch must be written; the remainder is chained.'
        );
    }

    @IsTest
    static void emptyAndUnknownInputsAreHarmless() {
        RIQ_AiInsightService.configOverride = config(true);
        Test.setMock(HttpCalloutMock.class, new RIQ_CalloutMocks.Recorder());

        Test.startTest();
        System.enqueueJob(new RIQ_AiInsightQueueable(new Set<Id>()));
        System.enqueueJob(new RIQ_AiInsightQueueable(null));
        Test.stopTest();

        Integer withSummary = 0;

        for (Account account : [SELECT RIQ_AI_Summary__c FROM Account]) {
            if (String.isNotBlank(account.RIQ_AI_Summary__c)) {
                withSummary++;
            }
        }

        System.assertEquals(0, withSummary);
    }

    @IsTest
    static void aFailingAccountDoesNotBlockTheRest() {
        List<Account> accounts = riskyAccounts(2);
        RIQ_AiInsightService.configOverride = config(true);
        Test.setMock(HttpCalloutMock.class, new RIQ_CalloutMocks.Responder(500, 'boom'));

        Test.startTest();
        System.enqueueJob(new RIQ_AiInsightQueueable(new Map<Id, Account>(accounts).keySet()));
        Test.stopTest();

        List<Account> updated = [
            SELECT RIQ_AI_Summary__c, RIQ_AI_Source__c
            FROM Account
            WHERE Id IN :accounts
        ];

        for (Account account : updated) {
            System.assertEquals(RIQ_AiInsightService.SOURCE_RULE_BASED, account.RIQ_AI_Source__c);
            System.assert(String.isNotBlank(account.RIQ_AI_Summary__c), 'A failed call still leaves a usable insight.');
        }
    }

    @IsTest
    static void emptyAndUnknownWorkIsSkipped() {
        RIQ_AiInsightService.configOverride = config(true);
        Test.setMock(HttpCalloutMock.class, new RIQ_CalloutMocks.Recorder());
        RIQ_AiInsightQueueable job = new RIQ_AiInsightQueueable(new Set<Id>());

        Test.startTest();
        job.generateFor(new List<Id>());
        job.generateFor(new List<Id>{ '001000000000001AAA' });
        Test.stopTest();

        System.assert(true, 'Neither a missing batch nor an unknown account may throw.');
    }
}
