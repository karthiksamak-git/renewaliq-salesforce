/**
 * @description Playbook contract: task and renewal creation, priority by band,
 * the 120-day renewal window boundary, idempotency against event replay and
 * against existing open work, and 200-event bulk safety.
 */
@IsTest
private class RIQ_PlaybookService_Test {
    /**
     * @param contractOffsetDays Contract end relative to today.
     * @return An inserted account with a known renewal date.
     */
    private static Account createAccount(Integer contractOffsetDays) {
        Account account = RIQ_TestDataFactory.createAccounts(1)[0];
        account.RIQ_Contract_End_Date__c = Date.today().addDays(contractOffsetDays);
        update account;

        // Re-read so OwnerId (which the factory does not set in memory) is
        // available for the assertions.
        return [
            SELECT Id, Name, OwnerId, RIQ_ARR__c, RIQ_Contract_End_Date__c
            FROM Account
            WHERE Id = :account.Id
        ];
    }

    /**
     * @param accountId Account the event refers to.
     * @param oldStatus Band before the change.
     * @param newStatus Band after the change.
     * @param score Score at the time of the change.
     * @return An unsaved platform event.
     */
    private static RIQ_Health_Status_Change__e buildEvent(
        Id accountId,
        String oldStatus,
        String newStatus,
        Integer score
    ) {
        return new RIQ_Health_Status_Change__e(
            AccountId__c = String.valueOf(accountId),
            OldStatus__c = oldStatus,
            NewStatus__c = newStatus,
            Score__c = score
        );
    }

    /**
     * @param events Events to publish, chunked to stay inside the publish cap.
     */
    private static void publishAndDeliver(List<RIQ_Health_Status_Change__e> events) {
        for (Integer start = 0; start < events.size(); start += 100) {
            List<RIQ_Health_Status_Change__e> chunk = new List<RIQ_Health_Status_Change__e>();

            for (Integer i = start; i < Math.min(start + 100, events.size()); i++) {
                chunk.add(events[i]);
            }

            EventBus.publish(chunk);
        }

        Test.getEventBus().deliver();
    }

    @IsTest
    static void criticalCreatesHighPriorityTaskAndRenewal() {
        Account account = createAccount(60);

        Test.startTest();
        publishAndDeliver(new List<RIQ_Health_Status_Change__e>{ buildEvent(account.Id, 'Watch', 'Critical', 12) });
        Test.stopTest();

        Task outreach = [
            SELECT Subject, Priority, ActivityDate, OwnerId, WhatId, Status
            FROM Task
            WHERE WhatId = :account.Id
        ];

        System.assertEquals(RIQ_PlaybookService.TASK_SUBJECT_PREFIX + account.Name, outreach.Subject);
        System.assertEquals('High', outreach.Priority);
        // A one day tolerance, not a looser check: the platform event trigger can run
        // as a user in another time zone, so its "today" can be a day either side of
        // the test's. A scratch org caught this - the exact comparison passed in the
        // Developer org and failed there, which is the definition of a flaky test.
        Integer daysUntilDue = Date.today().daysBetween(outreach.ActivityDate);
        System.assert(
            Math.abs(daysUntilDue - RIQ_PlaybookService.TASK_DUE_IN_DAYS) <= 1,
            'Expected the task to be due in about ' +
                RIQ_PlaybookService.TASK_DUE_IN_DAYS +
                ' days but it is due in ' +
                daysUntilDue +
                ' days.'
        );
        System.assertEquals(account.OwnerId, outreach.OwnerId);
        System.assertEquals('Not Started', outreach.Status);

        Opportunity renewal = [
            SELECT Name, Type, StageName, CloseDate, Amount, AccountId
            FROM Opportunity
            WHERE AccountId = :account.Id
        ];

        System.assertEquals(account.Name + ' Renewal', renewal.Name);
        System.assertEquals(RIQ_PlaybookService.RENEWAL_OPPORTUNITY_TYPE, renewal.Type);
        System.assertEquals(RIQ_PlaybookService.RENEWAL_STAGE, renewal.StageName);
        System.assertEquals(Date.today().addDays(60), renewal.CloseDate);
        System.assertEquals(account.RIQ_ARR__c, renewal.Amount);
    }

    @IsTest
    static void atRiskCreatesNormalPriorityTask() {
        Account account = createAccount(30);

        Test.startTest();
        publishAndDeliver(new List<RIQ_Health_Status_Change__e>{ buildEvent(account.Id, 'Watch', 'At Risk', 45) });
        Test.stopTest();

        System.assertEquals('Normal', [SELECT Priority FROM Task WHERE WhatId = :account.Id].Priority);
    }

    @IsTest
    static void watchAndHealthyEventsCreateNothing() {
        Account account = createAccount(30);

        Test.startTest();
        publishAndDeliver(
            new List<RIQ_Health_Status_Change__e>{
                buildEvent(account.Id, 'Critical', 'Watch', 70),
                buildEvent(account.Id, 'Watch', 'Healthy', 95)
            }
        );
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Task]);
        System.assertEquals(0, [SELECT COUNT() FROM Opportunity]);
    }

    @IsTest
    static void eventsWithoutAccountOrStatusAreIgnored() {
        Test.startTest();
        publishAndDeliver(
            new List<RIQ_Health_Status_Change__e>{
                buildEvent(null, 'Watch', 'Critical', 10),
                buildEvent(UserInfo.getUserId(), 'Healthy', null, 10)
            }
        );
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Task]);
    }

    @IsTest
    static void renewalWindowIsInclusiveOfOneHundredTwentyDays() {
        // The boundary is asserted against the service's own predicate, inside one
        // context. Driving it through the platform event compares the test's "today"
        // with the trigger runner's "today", and those are not the same day when the
        // runner is in another time zone - which is what a scratch org exposed.
        Account boundary = createAccount(RIQ_PlaybookService.RENEWAL_WINDOW_DAYS);
        Account justOutside = createAccount(RIQ_PlaybookService.RENEWAL_WINDOW_DAYS + 1);
        Account expired = createAccount(-1);
        Account noContractDate = createAccount(30);
        noContractDate.RIQ_Contract_End_Date__c = null;
        update noContractDate;

        System.assertEquals(true, RIQ_PlaybookService.isRenewalWindowOpen(boundary), 'Day 120 is inside.');
        System.assertEquals(false, RIQ_PlaybookService.isRenewalWindowOpen(justOutside), 'Day 121 is outside.');
        System.assertEquals(
            false,
            RIQ_PlaybookService.isRenewalWindowOpen(expired),
            'A lapsed contract is not a renewal.'
        );
        System.assertEquals(
            false,
            RIQ_PlaybookService.isRenewalWindowOpen(noContractDate),
            'No contract end date means nothing to renew.'
        );
    }

    @IsTest
    static void renewalOpportunityIsCreatedForAnAccountWellInsideTheWindow() {
        // The end-to-end path, kept away from the boundary so a time-zone difference
        // between this context and the event trigger cannot change the outcome.
        Account inside = createAccount(60);
        Account outside = createAccount(RIQ_PlaybookService.RENEWAL_WINDOW_DAYS + 200);

        Test.startTest();
        publishAndDeliver(
            new List<RIQ_Health_Status_Change__e>{
                buildEvent(inside.Id, 'Watch', 'At Risk', 50),
                buildEvent(outside.Id, 'Watch', 'At Risk', 50)
            }
        );
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Opportunity WHERE AccountId = :inside.Id], 'Day 60 renews.');
        System.assertEquals(0, [SELECT COUNT() FROM Opportunity WHERE AccountId = :outside.Id], 'Day 320 does not.');
    }

    @IsTest
    static void duplicateEventsInOneDeliveryCreateOneTask() {
        Account account = createAccount(400);
        RIQ_Health_Status_Change__e first = buildEvent(account.Id, 'Watch', 'Critical', 5);
        RIQ_Health_Status_Change__e replay = buildEvent(account.Id, 'Watch', 'Critical', 5);

        Test.startTest();
        publishAndDeliver(new List<RIQ_Health_Status_Change__e>{ first, replay });
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :account.Id]);
    }

    @IsTest
    static void redeliveredEventDoesNotDuplicateWork() {
        Account account = createAccount(400);
        List<RIQ_Health_Status_Change__e> events = new List<RIQ_Health_Status_Change__e>{
            buildEvent(account.Id, 'Watch', 'Critical', 5)
        };

        Test.startTest();
        publishAndDeliver(events);
        // At-least-once delivery: the same event arrives a second time.
        publishAndDeliver(events);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :account.Id]);
        System.assertEquals(0, [SELECT COUNT() FROM Opportunity WHERE AccountId = :account.Id]);
    }

    @IsTest
    static void existingOpenTaskBlocksADuplicate() {
        Account account = createAccount(400);
        insert new Task(
            Subject = RIQ_PlaybookService.TASK_SUBJECT_PREFIX + account.Name,
            WhatId = account.Id,
            OwnerId = account.OwnerId,
            ActivityDate = Date.today().addDays(1),
            Status = 'Not Started'
        );

        Test.startTest();
        publishAndDeliver(new List<RIQ_Health_Status_Change__e>{ buildEvent(account.Id, 'Watch', 'Critical', 5) });
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :account.Id]);
    }

    @IsTest
    static void existingOpenRenewalBlocksASecondOpportunity() {
        Account account = createAccount(60);
        insert new Opportunity(
            Name = account.Name + ' Renewal (existing)',
            AccountId = account.Id,
            Type = RIQ_PlaybookService.RENEWAL_OPPORTUNITY_TYPE,
            StageName = RIQ_PlaybookService.RENEWAL_STAGE,
            CloseDate = Date.today().addDays(60),
            Amount = account.RIQ_ARR__c
        );

        Test.startTest();
        publishAndDeliver(new List<RIQ_Health_Status_Change__e>{ buildEvent(account.Id, 'Watch', 'Critical', 5) });
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Opportunity WHERE AccountId = :account.Id]);
    }

    @IsTest
    static void missingOrPastContractEndCreatesNoOpportunity() {
        Account noContract = createAccount(60);
        noContract.RIQ_Contract_End_Date__c = null;
        update noContract;

        Account overdue = createAccount(-5);

        Test.startTest();
        publishAndDeliver(
            new List<RIQ_Health_Status_Change__e>{
                buildEvent(noContract.Id, 'Watch', 'Critical', 5),
                buildEvent(overdue.Id, 'Watch', 'Critical', 5)
            }
        );
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Opportunity]);
        System.assertEquals(2, [SELECT COUNT() FROM Task], 'The outreach task does not depend on the renewal window.');
    }

    @IsTest
    static void twoHundredEventsAreHandledInBulk() {
        List<Account> accounts = RIQ_TestDataFactory.createAccounts(200);

        for (Account account : accounts) {
            account.RIQ_Contract_End_Date__c = Date.today().addDays(45);
        }

        update accounts;

        List<RIQ_Health_Status_Change__e> events = new List<RIQ_Health_Status_Change__e>();

        for (Account account : accounts) {
            events.add(buildEvent(account.Id, 'Watch', 'Critical', 8));
        }

        Test.startTest();
        publishAndDeliver(events);
        Test.stopTest();

        System.assertEquals(200, [SELECT COUNT() FROM Task WHERE Subject LIKE 'Executive outreach%']);
        System.assertEquals(
            200,
            [SELECT COUNT() FROM Opportunity WHERE Type = :RIQ_PlaybookService.RENEWAL_OPPORTUNITY_TYPE]
        );
    }

    @IsTest
    static void deletedAccountIsSkipped() {
        Account account = createAccount(60);
        Id accountId = account.Id;
        RIQ_Health_Status_Change__e event = buildEvent(accountId, 'Watch', 'Critical', 5);
        delete account;

        Test.startTest();
        publishAndDeliver(new List<RIQ_Health_Status_Change__e>{ event });
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Task]);
    }

    @IsTest
    static void emptyEventBatchIsANoOp() {
        Test.startTest();
        RIQ_PlaybookService.PlaybookResult result = RIQ_PlaybookService.run(new List<SObject>());
        Test.stopTest();

        System.assertEquals(0, result.tasksCreated);
        System.assertEquals(0, result.opportunitiesCreated);
    }

    @IsTest
    static void aRejectedTaskIsCountedAndNeverThrown() {
        // One unsaveable task must not abort the batch: the other 199 accounts in
        // the delivery still need their outreach. The insert is partial-save on
        // purpose, and the failure is returned as a count.
        Test.startTest();
        Integer inserted = RIQ_PlaybookService.insertTasks(
            new List<Task>{
                new Task(
                    Subject = RIQ_PlaybookService.TASK_SUBJECT_PREFIX + 'Orphan',
                    WhatId = RIQ_TestDataFactory.nonExistentAccountId(),
                    ActivityDate = Date.today(),
                    Status = 'Not Started'
                )
            }
        );
        Test.stopTest();

        System.assertEquals(0, inserted, 'A rejected task is counted, never thrown.');
    }

    @IsTest
    static void aRejectedRenewalIsCountedAndNeverThrown() {
        // Same contract for the renewal motion: a bad opportunity is a count, not
        // an exception that rolls back every task created in the same delivery.
        Test.startTest();
        Integer inserted = RIQ_PlaybookService.insertOpportunities(
            new List<Opportunity>{
                new Opportunity(
                    Name = 'Orphan Renewal',
                    AccountId = RIQ_TestDataFactory.nonExistentAccountId(),
                    Type = RIQ_PlaybookService.RENEWAL_OPPORTUNITY_TYPE,
                    StageName = RIQ_PlaybookService.RENEWAL_STAGE,
                    CloseDate = Date.today(),
                    Amount = 1000
                )
            }
        );
        Test.stopTest();

        System.assertEquals(0, inserted);
    }
}
