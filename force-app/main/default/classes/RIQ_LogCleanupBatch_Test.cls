/**
 * @description Proves retention actually deletes the right rows and nothing
 * else, and that the schedule can be created twice without producing two jobs.
 */
@IsTest
private class RIQ_LogCleanupBatch_Test {
    @IsTest
    static void deletesOnlyRowsOlderThanRetention() {
        insert new List<RIQ_Log__c>{
            new RIQ_Log__c(
                Level__c = RIQ_Logger.LEVEL_INFO,
                Source__c = 'RIQ_LogCleanupBatch_Test',
                Message__c = 'Old line',
                Logged_At__c = DateTime.now().addDays(-90)
            ),
            new RIQ_Log__c(
                Level__c = RIQ_Logger.LEVEL_ERROR,
                Source__c = 'RIQ_LogCleanupBatch_Test',
                Message__c = 'Recent line',
                Logged_At__c = DateTime.now().addDays(-1)
            )
        };

        Test.startTest();
        Database.executeBatch(new RIQ_LogCleanupBatch(30), 200);
        Test.stopTest();

        // The run writes its own completion line, which is a new row and not a
        // survivor, so the assertion is about which messages remain rather than
        // how many.
        Set<String> remainingMessages = new Set<String>();

        for (RIQ_Log__c row : [SELECT Message__c FROM RIQ_Log__c]) {
            remainingMessages.add(row.Message__c);
        }

        Assert.isFalse(remainingMessages.contains('Old line'), 'The expired row should be gone.');
        Assert.isTrue(remainingMessages.contains('Recent line'), 'The recent row must survive.');
    }

    @IsTest
    static void keepsEverythingInsideTheWindow() {
        insert new RIQ_Log__c(
            Level__c = RIQ_Logger.LEVEL_INFO,
            Source__c = 'RIQ_LogCleanupBatch_Test',
            Message__c = 'Young line',
            Logged_At__c = DateTime.now()
        );

        Test.startTest();
        Database.executeBatch(new RIQ_LogCleanupBatch(365), 200);
        Test.stopTest();

        Set<String> messages = new Set<String>();

        for (RIQ_Log__c row : [SELECT Message__c FROM RIQ_Log__c]) {
            messages.add(row.Message__c);
        }

        Assert.isTrue(messages.contains('Young line'), 'A row inside the window must survive.');
    }

    @IsTest
    static void refusesAnUnusableWindow() {
        Assert.areEqual(RIQ_LogCleanupBatch.DEFAULT_RETENTION_DAYS, new RIQ_LogCleanupBatch(0).retentionDays);
        Assert.areEqual(RIQ_LogCleanupBatch.DEFAULT_RETENTION_DAYS, new RIQ_LogCleanupBatch(-5).retentionDays);
        Assert.areEqual(RIQ_LogCleanupBatch.DEFAULT_RETENTION_DAYS, new RIQ_LogCleanupBatch(null).retentionDays);
        Assert.areEqual(7, new RIQ_LogCleanupBatch(7).retentionDays);
        Assert.isTrue(RIQ_LogCleanupBatch.resolveRetentionDays() >= 1, 'Configuration must never produce a zero-day window.');
    }

    @IsTest
    static void anEmptyChunkIsIgnoredAndAStaleJobIdIsSurvivable() {
        Test.startTest();
        new RIQ_LogCleanupBatch(30).execute(null, new List<SObject>());
        RIQ_LogCleanupBatch.abortQuietly(null);
        Test.stopTest();

        String warningLevel = RIQ_Logger.LEVEL_WARNING;

        Assert.areEqual(0, [SELECT COUNT() FROM RIQ_Log__c WHERE Level__c = :RIQ_Logger.LEVEL_ERROR], 'An unusable id is not an error.');
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM RIQ_Log__c WHERE Level__c = :warningLevel],
            'A stale job id must be reported as a warning, not swallowed.'
        );
    }

    @IsTest
    static void theScheduledEntryPointLaunchesTheBatch() {
        Test.startTest();
        new RIQ_LogCleanupBatch(30).execute(null);
        Test.stopTest();

        Assert.areEqual(
            1,
            [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'BatchApex' AND ApexClass.Name = 'RIQ_LogCleanupBatch'],
            'The schedulable entry point must hand the work to the batch.'
        );
    }

    @IsTest
    static void schedulingTwiceKeepsOneJob() {
        Test.startTest();
        Id firstJobId = RIQ_LogCleanupBatch.schedule();
        Id secondJobId = RIQ_LogCleanupBatch.schedule();
        Test.stopTest();

        Assert.isNotNull(firstJobId);
        Assert.isNotNull(secondJobId);
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :RIQ_LogCleanupBatch.JOB_NAME],
            'Re-running the schedule must replace the job, not add a second one.'
        );
    }
}
