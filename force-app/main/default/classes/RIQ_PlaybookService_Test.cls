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
        System.assertEquals(Date.today().addDays(RIQ_PlaybookService.TASK_DUE_IN_DAYS), outreach.ActivityDate);
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
        Account inside = createAccount(120);
        Account outside = createAccount(121);

        Test.startTest();
        publishAndDeliver(
            new List<RIQ_Health_Status_Change__e>{
                buildEvent(inside.Id, 'Watch', 'At Risk', 50),
                buildEvent(outside.Id, 'Watch', 'At Risk', 50)
            }
        );
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Opportunity WHERE AccountId = :inside.Id], 'Day 120 is inside.');
        System.assertEquals(0, [SELECT COUNT() FROM Opportunity WHERE AccountId = :outside.Id], 'Day 121 is outside.');
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
        System.assertEquals(200, [SELECT COUNT() FROM Opportunity WHERE Type = :RIQ_PlaybookService.RENEWAL_OPPORTUNITY_TYPE]);
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
}
