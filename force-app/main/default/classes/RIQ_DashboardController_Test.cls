/**
 * @description Dashboard contract: aggregates, filters, sorting, clamping,
 * permission behaviour with System.runAs, and a 200-account book.
 */
@IsTest
private class RIQ_DashboardController_Test {
    private static final Integer BOOK_SIZE = 200;

    /**
     * @description Users and their permission set assignments are setup-object
     * DML, which cannot share a transaction with Account DML. @TestSetup runs in
     * its own transaction, so every test method below is free to create data.
     */
    @TestSetup
    static void createViewers() {
        RIQ_TestDataFactory.createUserWithPermissionSets('riqcsm', new List<String>{ 'RIQ_CSM' });
        RIQ_TestDataFactory.createUserWithPermissionSets('riqro', new List<String>{ 'RIQ_Read_Only' });
        RIQ_TestDataFactory.createUserWithPermissionSets('riqnop', new List<String>());
        RIQ_TestDataFactory.createUserWithPermissionSets('riqown', new List<String>{ 'RIQ_CSM' });
    }

    /**
     * @param alias Alias used when the user was created.
     * @return The test user.
     */
    private static User userByAlias(String alias) {
        return [SELECT Id, Alias FROM User WHERE Alias = :alias LIMIT 1];
    }

    /**
     * @return 200 accounts spread across all four statuses.
     */
    private static List<Account> createBook() {
        List<Account> accounts = new List<Account>();
        String suffix = String.valueOf(DateTime.now().getTime());

        for (Integer i = 0; i < BOOK_SIZE; i++) {
            String status;
            if (i < 50) {
                status = 'Critical';
            } else if (i < 100) {
                status = 'At Risk';
            } else if (i < 150) {
                status = 'Watch';
            } else {
                status = 'Healthy';
            }

            accounts.add(
                new Account(
                    Name = 'RIQ Dash ' + suffix + '-' + i,
                    RIQ_ARR__c = 10000 + i,
                    RIQ_Health_Status__c = status,
                    RIQ_Health_Score__c = Math.mod(i, 100),
                    RIQ_Churn_Probability__c = Math.mod(i * 2, 100),
                    RIQ_Contract_End_Date__c = Date.today().addDays(Math.mod(i * 7, 400))
                )
            );
        }

        insert accounts;
        return accounts;
    }

    @IsTest
    static void kpisAggregateTheWholeBook() {
        List<Account> accounts = createBook();

        Decimal expectedArr = 0;
        Decimal expectedAtRiskArr = 0;
        Decimal scoreTotal = 0;
        Integer expectedRenewals = 0;

        for (Account account : accounts) {
            expectedArr += account.RIQ_ARR__c;
            scoreTotal += account.RIQ_Health_Score__c;

            if (account.RIQ_Health_Status__c == 'At Risk' || account.RIQ_Health_Status__c == 'Critical') {
                expectedAtRiskArr += account.RIQ_ARR__c;
            }

            if (account.RIQ_Contract_End_Date__c >= Date.today() &&
                account.RIQ_Contract_End_Date__c <= Date.today().addDays(90)) {
                expectedRenewals++;
            }
        }

        Test.startTest();
        RIQ_DashboardController.Kpi kpi = RIQ_DashboardController.getKpis(null, 90);
        Test.stopTest();

        System.assertEquals(BOOK_SIZE, kpi.accountCount);
        System.assertEquals(expectedArr.setScale(2), kpi.totalArr.setScale(2));
        System.assertEquals(expectedAtRiskArr.setScale(2), kpi.arrAtRisk.setScale(2));
        System.assertEquals(50, kpi.criticalCount);
        System.assertEquals(expectedRenewals, kpi.renewalsDue);
        System.assertEquals(90, kpi.renewalWindowDays);
        System.assertEquals(
            (scoreTotal / BOOK_SIZE).setScale(1, RoundingMode.HALF_UP),
            kpi.averageScore.setScale(1)
        );
    }

    @IsTest
    static void kpisRespectTheOwnerFilter() {
        List<Account> accounts = createBook();
        User otherOwner = userByAlias('riqown');

        List<Account> reassigned = new List<Account>();

        for (Integer i = 0; i < 5; i++) {
            reassigned.add(new Account(Id = accounts[i].Id, OwnerId = otherOwner.Id));
        }

        update reassigned;

        Test.startTest();
        RIQ_DashboardController.Kpi mine = RIQ_DashboardController.getKpis(
            UserInfo.getUserId(),
            90
        );
        RIQ_DashboardController.Kpi theirs = RIQ_DashboardController.getKpis(otherOwner.Id, 90);
        Test.stopTest();

        System.assertEquals(5, theirs.accountCount);
        System.assertEquals(BOOK_SIZE - 5, mine.accountCount);
        System.assert(theirs.totalArr > 0);
    }

    @IsTest
    static void statusDistributionIsWorstFirstAndPercentageSumsTo100() {
        createBook();

        Test.startTest();
        List<RIQ_DashboardController.StatusSlice> slices = RIQ_DashboardController.getStatusDistribution(null);
        Test.stopTest();

        System.assertEquals(4, slices.size());
        System.assertEquals('Critical', slices[0].label);
        System.assertEquals('At Risk', slices[1].label);
        System.assertEquals('Watch', slices[2].label);
        System.assertEquals('Healthy', slices[3].label);
        System.assertEquals(50, slices[0].count);

        Decimal percentageTotal = 0;
        for (RIQ_DashboardController.StatusSlice slice : slices) {
            percentageTotal += slice.percentage;
        }

        System.assertEquals(100, percentageTotal.setScale(0).intValue());
    }

    @IsTest
    static void atRiskTableDefaultsToRiskStatuses() {
        createBook();

        Test.startTest();
        List<RIQ_DashboardController.RiskRow> rows = RIQ_DashboardController.getAtRiskAccounts(
            null,
            null,
            null,
            'score',
            'DESC',
            50
        );
        Test.stopTest();

        System.assertEquals(50, rows.size());

        for (RIQ_DashboardController.RiskRow row : rows) {
            System.assert(
                row.status == 'At Risk' || row.status == 'Critical',
                'Default scope is At Risk + Critical, got ' + row.status
            );
            System.assertNotEquals(null, row.recordUrl);
            System.assertEquals('/' + row.accountId, row.recordUrl);
        }
    }

    @IsTest
    static void atRiskTableFiltersByStatusAndRenewalWindow() {
        createBook();

        Test.startTest();
        List<RIQ_DashboardController.RiskRow> watchOnly = RIQ_DashboardController.getAtRiskAccounts(
            'Watch',
            null,
            null,
            'score',
            'DESC',
            200
        );
        List<RIQ_DashboardController.RiskRow> nextThirtyDays = RIQ_DashboardController.getAtRiskAccounts(
            'All',
            null,
            30,
            'renewal',
            'ASC',
            200
        );
        Test.stopTest();

        System.assertEquals(50, watchOnly.size());

        for (RIQ_DashboardController.RiskRow row : watchOnly) {
            System.assertEquals('Watch', row.status);
        }

        System.assert(!nextThirtyDays.isEmpty(), 'Some contracts end inside 30 days.');

        for (RIQ_DashboardController.RiskRow row : nextThirtyDays) {
            System.assert(row.daysToRenewal >= 0 && row.daysToRenewal <= 30, 'Outside the 30 day window.');
        }
    }

    @IsTest
    static void rowCountMatchesTheSameFiltersAsTheTable() {
        List<Account> accounts = createBook();
        User otherOwner = userByAlias('riqown');
        update new List<Account>{ new Account(Id = accounts[0].Id, OwnerId = otherOwner.Id) };

        Test.startTest();
        Integer allRisk = RIQ_DashboardController.getRowCount(null, null, null);
        Integer watchOnly = RIQ_DashboardController.getRowCount('Watch', null, null);
        Integer ownedByOther = RIQ_DashboardController.getRowCount('All', otherOwner.Id, null);
        Integer nextThirtyDays = RIQ_DashboardController.getRowCount('All', null, 30);
        Test.stopTest();

        System.assertEquals(100, allRisk, 'At Risk + Critical, any renewal date.');
        System.assertEquals(50, watchOnly, 'Watch only.');
        System.assertEquals(1, ownedByOther, 'Owner filter narrows the count.');
        System.assert(nextThirtyDays > 0 && nextThirtyDays <= 100, 'Window filter narrows the count.');
    }

    @IsTest
    static void atRiskTableSortsAndClampsRows() {
        List<Account> accounts = createBook();

        Test.startTest();
        List<RIQ_DashboardController.RiskRow> byArr = RIQ_DashboardController.getAtRiskAccounts(
            'All',
            null,
            null,
            'arr',
            'DESC',
            1000
        );
        List<RIQ_DashboardController.RiskRow> byNameAscending = RIQ_DashboardController.getAtRiskAccounts(
            'All',
            null,
            null,
            'name',
            'ASC',
            10
        );
        RIQ_DashboardController.Kpi windowClamp = RIQ_DashboardController.getKpis(null, 5000);
        Test.stopTest();

        System.assertEquals(100, byArr.size(), 'Clamped to the 200 row ceiling, 100 risk rows exist.');
        System.assert(byArr[0].arr >= byArr[byArr.size() - 1].arr, 'ARR must descend.');

        System.assertEquals(10, byNameAscending.size());
        System.assert(byNameAscending[0].name.compareTo(byNameAscending[1].name) <= 0, 'Names must ascend.');

        System.assertEquals(730, windowClamp.renewalWindowDays, 'Window is clamped.');
        System.assert(accounts.size() == BOOK_SIZE);
    }

    @IsTest
    static void unknownSortFieldFallsBackInsteadOfFailing() {
        createBook();

        Test.startTest();
        List<RIQ_DashboardController.RiskRow> rows = RIQ_DashboardController.getAtRiskAccounts(
            'All',
            null,
            null,
            'RIQ_Health_Score__c DESC; DROP TABLE Account',
            'sideways',
            10
        );
        Test.stopTest();

        System.assertEquals(10, rows.size());
    }

    @IsTest
    static void invalidStatusFilterIsRejected() {
        Test.startTest();
        Boolean rejected = false;

        try {
            RIQ_DashboardController.getAtRiskAccounts('Nonsense', null, null, 'score', 'DESC', 10);
        } catch (AuraHandledException friendly) {
            rejected = true;
            System.assert(friendly.getMessage().contains('not a valid health status'));
        }

        Test.stopTest();
        System.assert(rejected, 'An unknown status must be rejected, not silently ignored.');
    }

    @IsTest
    static void ownersListReturnsDistinctOwners() {
        createBook();

        Test.startTest();
        List<RIQ_DashboardController.OwnerOption> owners = RIQ_DashboardController.getOwners();
        Test.stopTest();

        System.assertEquals(1, owners.size());
        System.assertEquals(UserInfo.getUserId(), owners[0].ownerId);
        System.assertNotEquals(null, owners[0].ownerName);
    }

    @IsTest
    static void csmSeesOnlyWhatTheyOwn() {
        User csm = userByAlias('riqcsm');

        System.runAs(csm) {
            insert new List<Account>{
                new Account(Name = 'RIQ CSM One', RIQ_ARR__c = 1000, RIQ_Health_Status__c = 'Critical', RIQ_Health_Score__c = 10),
                new Account(Name = 'RIQ CSM Two', RIQ_ARR__c = 2000, RIQ_Health_Status__c = 'At Risk', RIQ_Health_Score__c = 45),
                new Account(Name = 'RIQ CSM Three', RIQ_ARR__c = 3000, RIQ_Health_Status__c = 'Healthy', RIQ_Health_Score__c = 92)
            };

            Test.startTest();
            RIQ_DashboardController.Kpi kpi = RIQ_DashboardController.getKpis(null, 90);
            List<RIQ_DashboardController.RiskRow> rows = RIQ_DashboardController.getAtRiskAccounts(
                null,
                null,
                null,
                'score',
                'DESC',
                50
            );
            Test.stopTest();

            System.assertEquals(3, kpi.accountCount);
            System.assertEquals(3000, kpi.arrAtRisk.setScale(0).intValue());
            System.assertEquals(2, rows.size());
        }
    }

    @IsTest
    static void readOnlyUserCanReadTheDashboard() {
        User readOnly = userByAlias('riqro');
        Account account = new Account(
            Name = 'RIQ Read Only Book',
            RIQ_ARR__c = 5000,
            RIQ_Health_Status__c = 'Critical',
            RIQ_Health_Score__c = 5,
            OwnerId = readOnly.Id
        );
        insert account;

        System.runAs(readOnly) {
            Test.startTest();
            RIQ_DashboardController.Kpi kpi = RIQ_DashboardController.getKpis(null, 90);
            List<RIQ_DashboardController.RiskRow> rows = RIQ_DashboardController.getAtRiskAccounts(
                null,
                null,
                null,
                'score',
                'DESC',
                50
            );
            Test.stopTest();

            System.assertEquals(1, kpi.accountCount);
            System.assertEquals(1, rows.size());
        }
    }

    @IsTest
    static void userWithoutPermissionSetGetsFriendlyError() {
        User outsider = userByAlias('riqnop');

        System.runAs(outsider) {
            Test.startTest();
            Boolean rejected = false;

            try {
                RIQ_DashboardController.getKpis(null, 90);
            } catch (AuraHandledException friendly) {
                rejected = true;
                System.assert(friendly.getMessage().contains('permission set'), 'Message must tell them what to ask for.');
            }

            Test.stopTest();
            System.assert(rejected, 'A user with no access must be refused.');
        }
    }
}
