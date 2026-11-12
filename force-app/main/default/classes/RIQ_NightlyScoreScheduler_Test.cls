/**
 * @description Scheduler behaviour: scheduling twice leaves exactly one job, and
 * the scheduled execute() really launches the batch.
 */
@IsTest
private class RIQ_NightlyScoreScheduler_Test {
    @IsTest
    static void schedulingTwiceLeavesExactlyOneJob() {
        Test.startTest();
        RIQ_NightlyScoreScheduler.scheduleNightly();
        RIQ_NightlyScoreScheduler.scheduleNightly();
        Test.stopTest();

        List<CronTrigger> jobs = [
            SELECT Id, CronExpression
            FROM CronTrigger
            WHERE CronJobDetail.Name = :RIQ_NightlyScoreScheduler.JOB_NAME
        ];

        System.assertEquals(1, jobs.size(), 'Re-scheduling must replace, not duplicate.');
        System.assertEquals(RIQ_NightlyScoreScheduler.CRON_EXPRESSION, jobs[0].CronExpression);
    }

    @IsTest
    static void scheduledExecuteLaunchesTheBatch() {
        List<Account> accounts = RIQ_TestDataFactory.createAccounts(2);

        RIQ_TriggerHandler.bypass('RIQ_HealthSignalTriggerHandler');
        insert RIQ_TestDataFactory.buildSignalsForAccounts(
            accounts,
            RIQ_TestDataFactory.SUPPORT_ESCALATION,
            1,
            Date.today()
        );
        RIQ_TriggerHandler.clearBypass();

        Test.startTest();
        new RIQ_NightlyScoreScheduler().execute(null);
        Test.stopTest();

        System.assertEquals(2, [SELECT COUNT() FROM RIQ_Score_History__c]);
        for (Account scored : [SELECT RIQ_Health_Score__c FROM Account WHERE Id IN :accounts]) {
            System.assertEquals(75, scored.RIQ_Health_Score__c.intValue(), '25 * 1 = 25 points removed.');
        }
    }
}
