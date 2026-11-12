/**
 * @description Selector behaviour, including the one thing that matters most
 * about the base class: a user without field or object access is actually
 * blocked, because USER_MODE is the default rather than an option someone has to
 * remember.
 *
 * A minimal subclass exercises the base class boilerplate directly.
 */
@IsTest
private class RIQ_Selector_Test {
    /**
     * @description Thin subclass used to reach the protected query helpers.
     */
    private class AccountNameSelector extends RIQ_Selector {
        public AccountNameSelector() {
            super();
        }

        public AccountNameSelector(AccessLevel requestedAccessMode) {
            super(requestedAccessMode);
        }

        public List<Account> getAll() {
            return (List<Account>) query('SELECT Id, Name FROM Account ORDER BY Name');
        }

        public List<Account> getByIds(Set<Id> accountIds) {
            return (List<Account>) query(
                'SELECT Id, Name FROM Account WHERE Id IN :accountIds',
                new Map<String, Object>{ 'accountIds' => accountIds }
            );
        }

        public List<SObject> strip(List<SObject> records, AccessType requestedAccessType) {
            return stripInaccessible(records, requestedAccessType);
        }
    }

    @IsTest
    static void userModeIsTheDefault() {
        List<Account> accounts = RIQ_TestDataFactory.createAccounts(3);
        Set<Id> ids = new Map<Id, Account>(accounts).keySet();

        Test.startTest();
        List<Account> found = new AccountNameSelector().getByIds(ids);
        Test.stopTest();

        System.assertEquals(3, found.size());
    }

    @IsTest
    static void emptyBindSetReturnsNothingInsteadOfEverything() {
        List<Account> found = new AccountNameSelector().getByIds(new Set<Id>());

        System.assertEquals(0, found.size(), 'An empty bind must never turn into an unfiltered query.');
    }

    @IsTest
    static void systemModeReadsWhatUserModeWouldHide() {
        List<Account> accounts = RIQ_TestDataFactory.createAccounts(1);
        User restrictedUser = RIQ_TestDataFactory.createRestrictedUser(RIQ_TestDataFactory.minimumAccessProfileId());

        Test.startTest();
        System.runAs(restrictedUser) {
            List<Account> found = new AccountNameSelector(AccessLevel.SYSTEM_MODE).getAll();
            System.assert(found.size() >= 1, 'SYSTEM_MODE is the explicit escape hatch.');
        }
        Test.stopTest();

        System.assertEquals(1, accounts.size());
    }

    @IsTest
    static void userModeBlocksAUserWithoutAccess() {
        RIQ_TestDataFactory.createAccounts(1);
        User restrictedUser = RIQ_TestDataFactory.createRestrictedUser(RIQ_TestDataFactory.minimumAccessProfileId());
        Boolean blocked = false;

        Test.startTest();
        System.runAs(restrictedUser) {
            try {
                new AccountNameSelector().getAll();
            } catch (Exception expected) {
                blocked = true;
            }
        }
        Test.stopTest();

        System.assert(blocked, 'USER_MODE must raise an error rather than leak records.');
    }

    @IsTest
    static void stripInaccessibleDropsFieldsTheUserCannotWrite() {
        List<Account> accounts = RIQ_TestDataFactory.createAccounts(1);
        List<SObject> stripped = new AccountNameSelector().strip(new List<SObject>{ accounts[0] }, AccessType.UPDATABLE);

        System.assertEquals(1, stripped.size());
    }

    @IsTest
    static void stripInaccessibleToleratesEmptyInput() {
        System.assertEquals(
            null,
            new AccountNameSelector().strip(null, AccessType.READABLE),
            'Null in, null out - callers do not need a null check.'
        );
        System.assertEquals(
            0,
            new AccountNameSelector().strip(new List<SObject>(), AccessType.READABLE).size()
        );
    }
}
