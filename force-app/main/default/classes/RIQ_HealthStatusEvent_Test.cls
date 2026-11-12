/**
 * @description Event publishing contract of the shared recalculation path: an
 * event is published only on a real band transition, never for an unchanged
 * band, and never for a first score.
 */
@IsTest
private class RIQ_HealthStatusEvent_Test {
    /**
     * @param status Starting band; null models an account that was never scored.
     * @param contractOffsetDays Contract end relative to today.
     * @return The updated account.
     */
    private static Account createAccount(String status, Integer contractOffsetDays) {
        Account account = RIQ_TestDataFactory.createAccounts(1)[0];
        account.RIQ_Health_Status__c = status;
        account.RIQ_Contract_End_Date__c = Date.today().addDays(contractOffsetDays);
        update account;
        return account;
    }

    /**
     * @param account Account to attach a severe signal to.
     */
    private static void logSevereSignal(Account account) {
        RIQ_TriggerHandler.bypass('RIQ_HealthSignalTriggerHandler');
        insert RIQ_TestDataFactory.buildSignal(
            account.Id,
            RIQ_TestDataFactory.SUPPORT_ESCALATION,
            5,
            Date.today()
        );
        RIQ_TriggerHandler.clearBypass();
    }

    @IsTest
    static void publishesEventWhenTheBandChanges() {
        Account account = createAccount('Healthy', 60);
        logSevereSignal(account);

        Test.startTest();
        RIQ_HealthScoreRecalculator.ProcessResult result = RIQ_HealthScoreRecalculator.process(
            new Set<Id>{ account.Id }
        );
        Test.getEventBus().deliver();
        Test.stopTest();

        System.assertEquals(1, result.processedCount);
        System.assertEquals(1, result.statusChangeCount);
        System.assertEquals(0, result.eventFailureCount);
        System.assertEquals('Healthy', result.statusChanges[0].oldStatus);
        System.assertEquals('Critical', result.statusChanges[0].newStatus);
        System.assertEquals(0, result.statusChanges[0].score);

        System.assertEquals(
            1,
            [SELECT COUNT() FROM Task WHERE WhatId = :account.Id AND Subject LIKE 'Executive outreach%'],
            'The published event ran the playbook.'
        );
    }

    @IsTest
    static void publishesNothingWhenTheBandIsUnchanged() {
        Account account = createAccount('Critical', 400);
        logSevereSignal(account);

        Test.startTest();
        RIQ_HealthScoreRecalculator.ProcessResult result = RIQ_HealthScoreRecalculator.process(
            new Set<Id>{ account.Id }
        );
        Test.getEventBus().deliver();
        Test.stopTest();

        System.assertEquals(1, result.processedCount);
        System.assertEquals(0, result.statusChangeCount, 'Critical to Critical is not a transition.');
        System.assertEquals(0, [SELECT COUNT() FROM Task]);
        System.assertEquals(0, [SELECT COUNT() FROM Opportunity]);
    }

    @IsTest
    static void firstScoreIsABaselineAndPublishesNothing() {
        Account account = RIQ_TestDataFactory.createAccounts(1)[0];
        logSevereSignal(account);

        Test.startTest();
        RIQ_HealthScoreRecalculator.ProcessResult result = RIQ_HealthScoreRecalculator.process(
            new Set<Id>{ account.Id }
        );
        Test.getEventBus().deliver();
        Test.stopTest();

        System.assertEquals(1, result.processedCount);
        System.assertEquals(1, result.initialScoreCount);
        System.assertEquals(0, result.statusChangeCount, 'null -> status is a baseline, not an event.');
        System.assertEquals(0, [SELECT COUNT() FROM Task]);
    }
}
