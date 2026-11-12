/**
 * @description Verifies the account selector returns exactly the contract fields
 * the engine depends on, and nothing extra.
 */
@IsTest
private class RIQ_AccountSelector_Test {
    @IsTest
    static void loadsContractDataForBulkRecalculation() {
        List<Account> accounts = RIQ_TestDataFactory.createAccounts(3);

        Test.startTest();
        List<Account> found = new RIQ_AccountSelector(AccessLevel.SYSTEM_MODE)
            .getByIds(new Map<Id, Account>(accounts).keySet());
        Test.stopTest();

        System.assertEquals(3, found.size());
        System.assertNotEquals(null, found[0].RIQ_Contract_End_Date__c, 'Renewal date drives churn probability.');
        System.assertNotEquals(null, found[0].RIQ_ARR__c);
    }

    @IsTest
    static void emptyOrNullIdsReturnNothing() {
        System.assertEquals(0, new RIQ_AccountSelector().getByIds(new Set<Id>()).size());
        System.assertEquals(0, new RIQ_AccountSelector().getByIds(null).size());
    }

    @IsTest
    static void systemModeLoadsAccountsForUsersWithoutAccess() {
        List<Account> accounts = RIQ_TestDataFactory.createAccounts(1);
        User restrictedUser = RIQ_TestDataFactory.createRestrictedUser(RIQ_TestDataFactory.minimumAccessProfileId());

        Test.startTest();
        System.runAs(restrictedUser) {
            List<Account> found = new RIQ_AccountSelector(AccessLevel.SYSTEM_MODE)
                .getByIds(new Map<Id, Account>(accounts).keySet());
            System.assertEquals(1, found.size());
        }
        Test.stopTest();
    }
}
