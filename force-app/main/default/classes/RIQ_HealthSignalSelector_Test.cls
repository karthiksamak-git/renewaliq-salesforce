/**
 * @description Verifies the signal selector's query shape: bulk bind, ordering
 * and the empty-input guard that prevents an unfiltered query.
 */
@IsTest
private class RIQ_HealthSignalSelector_Test {
    @IsTest
    static void loadsSignalsForManyAccountsInOneQuery() {
        List<Account> accounts = RIQ_TestDataFactory.createAccounts(5);
        List<RIQ_Health_Signal__c> signals = new List<RIQ_Health_Signal__c>();

        for (Account account : accounts) {
            signals.add(
                RIQ_TestDataFactory.buildSignal(account.Id, RIQ_TestDataFactory.SUPPORT_ESCALATION, 3, Date.today())
            );
        }

        insert signals;

        Test.startTest();
        List<RIQ_Health_Signal__c> found = new RIQ_HealthSignalSelector(AccessLevel.SYSTEM_MODE)
            .getByAccountIds(new Map<Id, Account>(accounts).keySet());
        Test.stopTest();

        System.assertEquals(5, found.size());
        System.assertNotEquals(null, found[0].Signal_Type__c);
        System.assertNotEquals(null, found[0].Occurred_On__c);
    }

    @IsTest
    static void returnsNewestSignalsFirst() {
        List<Account> singleAccount = RIQ_TestDataFactory.createAccounts(1);
        Account account = singleAccount[0];
        insert new List<RIQ_Health_Signal__c>{
            RIQ_TestDataFactory.buildSignal(account.Id, RIQ_TestDataFactory.MISSED_QBR, 1, Date.today().addDays(-30)),
            RIQ_TestDataFactory.buildSignal(account.Id, RIQ_TestDataFactory.MISSED_QBR, 1, Date.today())
        };

        List<RIQ_Health_Signal__c> found = new RIQ_HealthSignalSelector(AccessLevel.SYSTEM_MODE)
            .getByAccountIds(new Set<Id>{ account.Id });

        System.assertEquals(2, found.size());
        System.assertEquals(Date.today(), found[0].Occurred_On__c, 'Newest first keeps history reads intuitive.');
    }

    @IsTest
    static void emptyOrNullIdsReturnNothing() {
        System.assertEquals(0, new RIQ_HealthSignalSelector().getByAccountIds(new Set<Id>()).size());
        System.assertEquals(0, new RIQ_HealthSignalSelector().getByAccountIds(null).size());
    }

    @IsTest
    static void systemModeWorksForUsersWithoutAccessToSignals() {
        List<Account> singleAccount = RIQ_TestDataFactory.createAccounts(1);
        Account account = singleAccount[0];
        insert RIQ_TestDataFactory.buildSignal(account.Id, RIQ_TestDataFactory.LOW_PRODUCT_USAGE, 2, Date.today());
        User restrictedUser = RIQ_TestDataFactory.createRestrictedUser(RIQ_TestDataFactory.minimumAccessProfileId());

        Test.startTest();
        System.runAs(restrictedUser) {
            List<RIQ_Health_Signal__c> found = new RIQ_HealthSignalSelector(AccessLevel.SYSTEM_MODE)
                .getByAccountIds(new Set<Id>{ account.Id });
            System.assertEquals(1, found.size());
        }
        Test.stopTest();
    }
}
