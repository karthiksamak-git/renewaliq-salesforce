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

    @IsTest
    static void schedulingSurvivesAJobThatCannotBeAborted() {
        // An admin cancels the job in Setup, then re-runs the scheduler. Depending
        // on timing the cancelled row is still visible to the query while it is in
        // the DELETED state, and aborting it a second time throws. A failure to
        // clean up an old job must never stop the new schedule from being created.
        Test.startTest();
        Id jobId = RIQ_NightlyScoreScheduler.scheduleNightly();
        System.abortJob(jobId);
        RIQ_NightlyScoreScheduler.scheduleNightly();
        Test.stopTest();

        List<CronTrigger> jobs = [
            SELECT Id, State
            FROM CronTrigger
            WHERE CronJobDetail.Name = :RIQ_NightlyScoreScheduler.JOB_NAME
        ];

        System.assertEquals(1, jobs.size(), 'One live schedule, whatever the old row was doing.');
        System.assertEquals('WAITING', jobs[0].State);
    }

    @IsTest
    static void abortingAJobThatIsAlreadyGoneIsQuiet() {
        // A job can vanish between the query and the abort. The catch is what keeps
        // an admin's re-schedule working, and it must log rather than throw.
        Test.startTest();
        // An id in the Account key prefix resolves to no job, which is the same
        // failure an admin sees when the job was cancelled between the query and
        // the abort. Built at runtime so the test carries no id literal.
        RIQ_NightlyScoreScheduler.abortQuietly(RIQ_TestDataFactory.nonExistentAccountId());
        Id scheduledId = RIQ_NightlyScoreScheduler.scheduleNightly();
        Test.stopTest();

        System.assertNotEquals(null, scheduledId, 'A stale job id must not stop the new schedule.');
        List<CronTrigger> jobs = [
            SELECT Id
            FROM CronTrigger
            WHERE CronJobDetail.Name = :RIQ_NightlyScoreScheduler.JOB_NAME
        ];
        System.assertEquals(1, jobs.size(), 'The new schedule exists and is the only one.');
    }
}
