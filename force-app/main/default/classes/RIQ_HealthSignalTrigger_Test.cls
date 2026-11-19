/**
 * @description End-to-end trigger behaviour. Every test drives real DML so the
 * trigger, the handler, the queueable and the engine are exercised together -
 * the only way to catch a handler that is correct in isolation and wrong in a
 * bulk transaction.
 */
@IsTest
private class RIQ_HealthSignalTrigger_Test {
    @IsTest
    static void bulkInsertScoresTwoHundredAccounts() {
        List<Account> accounts = RIQ_TestDataFactory.createAccounts(200);
        List<RIQ_Health_Signal__c> signals = RIQ_TestDataFactory.buildSignalsForAccounts(
            accounts,
            RIQ_TestDataFactory.SUPPORT_ESCALATION,
            5,
            Date.today()
        );

        Test.startTest();
        insert signals;
        Test.stopTest();

        List<Account> scored = [
            SELECT Id, RIQ_Health_Score__c, RIQ_Health_Status__c, RIQ_Last_Scored__c
            FROM Account
            WHERE Id IN :accounts
        ];

        System.assertEquals(200, scored.size());

        for (Account account : scored) {
            System.assertEquals(0, account.RIQ_Health_Score__c.intValue(), '25 * 5 saturates the penalty.');
            System.assertEquals('Critical', account.RIQ_Health_Status__c);
            System.assertNotEquals(null, account.RIQ_Last_Scored__c);
        }

        System.assertEquals(
            200,
            [SELECT COUNT() FROM RIQ_Score_History__c],
            'One history row per account, not per signal.'
        );
    }

    @IsTest
    static void severityChangeRescoresAndAppendsHistory() {
        List<Account> singleAccount = RIQ_TestDataFactory.createAccounts(1);
        Account account = singleAccount[0];
        RIQ_Health_Signal__c signal = RIQ_TestDataFactory.buildSignal(
            account.Id,
            RIQ_TestDataFactory.LOW_PRODUCT_USAGE,
            1,
            Date.today()
        );
        insert signal;

        Test.startTest();
        signal.Severity__c = 5;
        update signal;
        Test.stopTest();

        Account rescored = [SELECT RIQ_Health_Score__c FROM Account WHERE Id = :account.Id];
        System.assertEquals(25, rescored.RIQ_Health_Score__c.intValue(), '15 * 5 = 75 points removed from 100.');
        System.assertEquals(2, [SELECT COUNT() FROM RIQ_Score_History__c], 'Each recalculation is an audit row.');
    }

    @IsTest
    static void editingNotesDoesNotBurnAQueueable() {
        List<Account> singleAccount = RIQ_TestDataFactory.createAccounts(1);
        Account account = singleAccount[0];
        RIQ_Health_Signal__c signal = RIQ_TestDataFactory.buildSignal(
            account.Id,
            RIQ_TestDataFactory.LOW_PRODUCT_USAGE,
            2,
            Date.today()
        );
        insert signal;

        Test.startTest();
        signal.Notes__c = 'CSM added context that does not affect scoring.';
        update signal;
        Test.stopTest();

        System.assertEquals(
            1,
            [SELECT COUNT() FROM RIQ_Score_History__c],
            'No scoring input changed, so no recalculation.'
        );
    }

    @IsTest
    static void changingSignalTypeRescoresTheAccount() {
        List<Account> singleAccount = RIQ_TestDataFactory.createAccounts(1);
        Account account = singleAccount[0];
        RIQ_Health_Signal__c signal = RIQ_TestDataFactory.buildSignal(
            account.Id,
            RIQ_TestDataFactory.LOW_PRODUCT_USAGE,
            5,
            Date.today()
        );
        insert signal;

        Test.startTest();
        // Low Product Usage is 15 * 5 = 75 points; Support Escalation is 25 * 5 = 125.
        signal.Signal_Type__c = RIQ_TestDataFactory.SUPPORT_ESCALATION;
        update signal;
        Test.stopTest();

        Account rescored = [SELECT RIQ_Health_Score__c FROM Account WHERE Id = :account.Id];
        System.assertEquals(0, rescored.RIQ_Health_Score__c.intValue(), 'The new rule wins.');
        System.assertEquals(2, [SELECT COUNT() FROM RIQ_Score_History__c]);
    }

    @IsTest
    static void deletingASignalRaisesTheScore() {
        List<Account> singleAccount = RIQ_TestDataFactory.createAccounts(1);
        Account account = singleAccount[0];
        RIQ_Health_Signal__c signal = RIQ_TestDataFactory.buildSignal(
            account.Id,
            RIQ_TestDataFactory.SUPPORT_ESCALATION,
            5,
            Date.today()
        );
        insert signal;

        Test.startTest();
        delete signal;
        Test.stopTest();

        Account rescored = [SELECT RIQ_Health_Score__c FROM Account WHERE Id = :account.Id];
        System.assertEquals(100, rescored.RIQ_Health_Score__c.intValue());
        System.assertEquals(2, [SELECT COUNT() FROM RIQ_Score_History__c]);
    }

    @IsTest
    static void undeletingASignalLowersTheScoreAgain() {
        List<Account> singleAccount = RIQ_TestDataFactory.createAccounts(1);
        Account account = singleAccount[0];
        RIQ_Health_Signal__c signal = RIQ_TestDataFactory.buildSignal(
            account.Id,
            RIQ_TestDataFactory.SUPPORT_ESCALATION,
            5,
            Date.today()
        );
        insert signal;
        Id signalId = signal.Id;
        delete signal;

        Test.startTest();
        Database.undelete(signalId);
        Test.stopTest();

        Account rescored = [SELECT RIQ_Health_Score__c FROM Account WHERE Id = :account.Id];
        System.assertEquals(0, rescored.RIQ_Health_Score__c.intValue(), 'The restored signal counts again.');
        System.assertEquals(3, [SELECT COUNT() FROM RIQ_Score_History__c]);
    }

    @IsTest
    static void bypassingTheHandlerStopsScoringEntirely() {
        List<Account> singleAccount = RIQ_TestDataFactory.createAccounts(1);
        Account account = singleAccount[0];
        RIQ_TriggerHandler.bypass('RIQ_HealthSignalTriggerHandler');

        Test.startTest();
        insert RIQ_TestDataFactory.buildSignal(account.Id, RIQ_TestDataFactory.SUPPORT_ESCALATION, 5, Date.today());
        Test.stopTest();

        RIQ_TriggerHandler.clearBypass();

        Account untouched = [SELECT RIQ_Health_Score__c FROM Account WHERE Id = :account.Id];
        System.assertEquals(null, untouched.RIQ_Health_Score__c, 'Bypass must skip the whole handler.');
        System.assertEquals(0, [SELECT COUNT() FROM RIQ_Score_History__c]);
    }

    @IsTest
    static void fullQueueableQueueSkipsInsteadOfThrowing() {
        // In a transaction that has already burned the queueable allowance (a data
        // load, or a nested enqueue), the handler cannot score and must not throw:
        // a thrown exception would roll back the signal the CSM just recorded.
        // The skip is logged, and the nightly batch re-scores the book.
        List<Account> accounts = RIQ_TestDataFactory.createAccounts(2);
        Account target = accounts[0];
        Account filler = accounts[1];

        Test.startTest();

        // Fill the queue to whatever is left of its allowance. Asking for one more
        // is not an option: a queueable limit exception cannot be caught, so the
        // test would end at the enqueue instead of reaching the handler.
        Integer remaining = Limits.getLimitQueueableJobs() - Limits.getQueueableJobs();

        for (Integer i = 0; i < remaining; i++) {
            // OperationWithLimitsInLoop: exhausting the queueable allowance is the
            // whole point of this test - it is the only way to reach the guard.
            // prettier-ignore
            System.enqueueJob(new RIQ_HealthScoreRecalculator(new Set<Id>{ filler.Id })); // NOPMD intentional limit exhaustion
        }

        insert RIQ_TestDataFactory.buildSignal(target.Id, RIQ_TestDataFactory.SUPPORT_ESCALATION, 5, Date.today());
        Test.stopTest();

        Account untouched = [SELECT RIQ_Health_Score__c FROM Account WHERE Id = :target.Id];
        System.assertEquals(null, untouched.RIQ_Health_Score__c, 'Skipped, not thrown.');
        System.assertEquals(
            0,
            [SELECT COUNT() FROM RIQ_Score_History__c WHERE Account__c = :target.Id],
            'No score is written for the skipped account.'
        );
    }
}
