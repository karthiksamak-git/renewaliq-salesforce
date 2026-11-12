/**
 * @description The Flow cannot be unit tested the way Apex can, but it does run
 * inside Apex DML in a test. This proves the declarative piece cannot break the
 * score update: a Critical transition commits even when the notification cannot
 * be delivered (no manager set, or the notification type lookup returns
 * nothing in a test context).
 *
 * The visible outcome - the bell notification to the manager and the Chatter
 * post - is verified manually; see the Phase 3 section of the README.
 */
@IsTest
private class RIQ_AccountCriticalAlertFlow_Test {
    @IsTest
    static void criticalTransitionCommitsWhenFlowCannotNotify() {
        Account account = RIQ_TestDataFactory.createAccounts(1)[0];

        Test.startTest();
        account.RIQ_Health_Score__c = 12;
        account.RIQ_Health_Status__c = 'Critical';
        update account;
        Test.stopTest();

        Account updated = [SELECT RIQ_Health_Status__c, RIQ_Health_Score__c FROM Account WHERE Id = :account.Id];
        System.assertEquals('Critical', updated.RIQ_Health_Status__c, 'The Flow must never roll back the score.');
        System.assertEquals(12, updated.RIQ_Health_Score__c.intValue());
    }

    @IsTest
    static void criticalTransitionPostsToTheAccountFeed() {
        Account account = RIQ_TestDataFactory.createAccounts(1)[0];

        Test.startTest();
        account.RIQ_Health_Status__c = 'Critical';
        update account;
        Test.stopTest();

        System.assertEquals(
            1,
            [SELECT COUNT() FROM FeedItem WHERE ParentId = :account.Id],
            'The feed post must still happen when the owner has no manager.'
        );
    }

    @IsTest
    static void accountWithoutManagerDoesNotFault() {
        Account account = RIQ_TestDataFactory.createAccounts(1)[0];

        Test.startTest();
        account.RIQ_Health_Status__c = 'Critical';
        update account;
        account.RIQ_Health_Status__c = 'Healthy';
        update account;
        Test.stopTest();

        System.assertEquals(
            'Healthy',
            [SELECT RIQ_Health_Status__c FROM Account WHERE Id = :account.Id].RIQ_Health_Status__c
        );
    }
}
