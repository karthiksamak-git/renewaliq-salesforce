/**
 * @description Health card and signal logger: card shape, defensive JSON
 * parsing, trend ordering, permission enforcement with System.runAs, and input
 * validation.
 */
@IsTest
private class RIQ_AccountHealthController_Test {
    private static final String VALID_DRIVERS =
        '[{"signalType":"Support Escalation","severity":5,"points":125.00,"occurredOn":"2026-11-01",' +
        '"explanation":"Support Escalation (severity 5) removed 125.0 points"},' +
        '{"signalType":"Low Product Usage","severity":2,"points":30.00,"occurredOn":"2026-10-20",' +
        '"explanation":"Low Product Usage (severity 2) removed 30.0 points"}]';

    /**
     * @description Users and permission set assignments are setup-object DML and
     * cannot share a transaction with Account DML, so they are created here, in
     * the separate @TestSetup transaction.
     */
    @TestSetup
    static void createViewers() {
        RIQ_TestDataFactory.createUserWithPermissionSets('riqro', new List<String>{ 'RIQ_Read_Only' });
        RIQ_TestDataFactory.createUserWithPermissionSets('riqcsm', new List<String>{ 'RIQ_CSM' });
        RIQ_TestDataFactory.createUserWithPermissionSets('riqout', new List<String>{ 'RIQ_CSM' });
    }

    /**
     * @param alias Alias used when the user was created.
     * @return The test user.
     */
    private static User userByAlias(String alias) {
        return [SELECT Id, Alias FROM User WHERE Alias = :alias LIMIT 1];
    }

    /**
     * @param name Account name.
     * @return An inserted account with a score and a visible renewal date.
     */
    private static Account createAccount(String name) {
        Account account = new Account(
            Name = name,
            RIQ_ARR__c = 120000,
            RIQ_Contract_End_Date__c = Date.today().addDays(60),
            RIQ_Health_Score__c = 42,
            RIQ_Health_Status__c = 'At Risk',
            RIQ_Churn_Probability__c = 55,
            RIQ_Last_Scored__c = DateTime.now()
        );
        insert account;
        return account;
    }

    /**
     * @param accountId Account to attach history to.
     * @param score Score.
     * @param status Band.
     * @param calculatedOn When it was calculated.
     * @param driversJson Raw payload.
     */
    private static void addHistory(Id accountId, Integer score, String status, DateTime calculatedOn, String driversJson) {
        insert new RIQ_Score_History__c(
            Account__c = accountId,
            Score__c = score,
            Status__c = status,
            Calculated_On__c = calculatedOn,
            Drivers__c = driversJson
        );
    }

    @IsTest
    static void cardReturnsScoreDriversAndTrend() {
        Account account = createAccount('RIQ Card Account');
        DateTime base = DateTime.now().addDays(-3);
        addHistory(account.Id, 80, 'Healthy', base, VALID_DRIVERS);
        addHistory(account.Id, 60, 'Watch', base.addDays(1), null);
        addHistory(account.Id, 42, 'At Risk', base.addDays(2), VALID_DRIVERS);

        Test.startTest();
        RIQ_AccountHealthController.HealthCard card = RIQ_AccountHealthController.getHealthCard(account.Id);
        Test.stopTest();

        System.assertEquals(account.Id, card.accountId);
        System.assertEquals('RIQ Card Account', card.accountName);
        System.assertEquals(42, card.score);
        System.assertEquals('At Risk', card.status);
        System.assertEquals(55, card.churnProbability);
        System.assertEquals(120000, card.arr.setScale(0).intValue());
        System.assertEquals(Date.today().addDays(60), card.contractEndDate);
        System.assertEquals(2, card.drivers.size());
        System.assertEquals('Support Escalation', card.drivers[0].signalType);
        System.assertEquals(5, card.drivers[0].severity);
        System.assertEquals(125, card.drivers[0].points.setScale(0).intValue());
        System.assertEquals(Date.newInstance(2026, 11, 1), card.drivers[0].occurredOn);

        System.assertEquals(3, card.history.size(), 'Oldest first for the sparkline.');
        System.assertEquals(80, card.history[0].score);
        System.assertEquals(42, card.history[2].score);
    }

    @IsTest
    static void malformedDriversJsonDegradesToNoDrivers() {
        Account account = createAccount('RIQ Bad Json');
        List<String> unreadable = new List<String>{ '{not json', '{"a":1}', 'null' };

        Test.startTest();
        for (String payload : unreadable) {
            addHistory(account.Id, 42, 'At Risk', DateTime.now(), payload);
            RIQ_AccountHealthController.HealthCard card = RIQ_AccountHealthController.getHealthCard(account.Id);
            System.assertEquals(0, card.drivers.size(), 'Unreadable payload must not break the card: ' + payload);
        }

        // A readable array with an unreadable value degrades field by field.
        addHistory(account.Id, 42, 'At Risk', DateTime.now().addMinutes(1), '[{"severity":"many"}]');
        RIQ_AccountHealthController.HealthCard mostRecent = RIQ_AccountHealthController.getHealthCard(account.Id);
        System.assertEquals(1, mostRecent.drivers.size(), 'A partially valid entry still renders.');
        System.assertEquals(null, mostRecent.drivers[0].severity, 'A non-numeric severity becomes null.');
        Test.stopTest();
    }

    @IsTest
    static void driversAreCappedAtFive() {
        Account account = createAccount('RIQ Many Drivers');
        String many = '[';

        for (Integer i = 0; i < 8; i++) {
            many += (i > 0 ? ',' : '') +
                '{"signalType":"Support Escalation","severity":2,"points":10,"occurredOn":"2026-11-01","explanation":"x"}';
        }

        many += ']';
        addHistory(account.Id, 10, 'Critical', DateTime.now(), many);

        Test.startTest();
        RIQ_AccountHealthController.HealthCard card = RIQ_AccountHealthController.getHealthCard(account.Id);
        Test.stopTest();

        System.assertEquals(5, card.drivers.size(), 'Only the top five are sent to the client.');
    }

    @IsTest
    static void trendIsCappedAtTwelvePointsAndAscending() {
        Account account = createAccount('RIQ Long Trend');
        DateTime base = DateTime.now().addDays(-30);

        for (Integer i = 0; i < 20; i++) {
            addHistory(account.Id, 10 + i, 'Watch', base.addDays(i), null);
        }

        Test.startTest();
        RIQ_AccountHealthController.HealthCard card = RIQ_AccountHealthController.getHealthCard(account.Id);
        Test.stopTest();

        System.assertEquals(12, card.history.size());
        System.assertEquals(18, card.history[0].score, 'Newest twelve, oldest first.');
        System.assertEquals(29, card.history[11].score);
    }

    @IsTest
    static void cardWithoutHistoryStillRenders() {
        Account account = createAccount('RIQ No History');

        Test.startTest();
        RIQ_AccountHealthController.HealthCard card = RIQ_AccountHealthController.getHealthCard(account.Id);
        Test.stopTest();

        System.assertEquals(42, card.score);
        System.assertEquals(0, card.drivers.size());
        System.assertEquals(0, card.history.size());
    }

    /**
     * The selector is used directly as well as through the card, so its own
     * contract is covered separately: the explicit access level constructor, the
     * SOQL row limit, and the null-account guard.
     */
    @IsTest
    static void scoreHistorySelectorAppliesLimitsAndGuards() {
        Account account = createAccount('RIQ Selector Account');
        DateTime base = DateTime.now().addDays(-10);

        for (Integer i = 0; i < 5; i++) {
            addHistory(account.Id, 50 + i, 'Watch', base.addDays(i), null);
        }

        Test.startTest();
        List<RIQ_Score_History__c> limited = new RIQ_ScoreHistorySelector(AccessLevel.SYSTEM_MODE)
            .getLatestForAccount(account.Id, 3);
        List<RIQ_Score_History__c> nothing = new RIQ_ScoreHistorySelector().getLatestForAccount(null, 3);
        Test.stopTest();

        System.assertEquals(3, limited.size(), 'The row limit is applied by SOQL.');
        System.assertEquals(54, limited[0].Score__c, 'Newest row first.');
        System.assertEquals(0, nothing.size(), 'A null account is an empty trend, not an error.');
    }

    @IsTest
    static void missingAccountAndNullIdAreFriendly() {
        Test.startTest();
        Boolean nullRejected = false;
        Boolean missingRejected = false;

        try {
            RIQ_AccountHealthController.getHealthCard(null);
        } catch (AuraHandledException friendly) {
            nullRejected = true;
        }

        try {
            RIQ_AccountHealthController.getHealthCard('001000000000001AAA');
        } catch (AuraHandledException friendly) {
            missingRejected = true;
            System.assert(friendly.getMessage().contains('access'));
        }

        Test.stopTest();
        System.assert(nullRejected && missingRejected);
    }

    @IsTest
    static void readOnlyViewerSeesNoActions() {
        User readOnly = userByAlias('riqro');
        Account account = createAccount('RIQ Read Only Card');
        account.OwnerId = readOnly.Id;
        update account;

        System.runAs(readOnly) {
            Test.startTest();
            RIQ_AccountHealthController.HealthCard card = RIQ_AccountHealthController.getHealthCard(account.Id);
            Test.stopTest();

            System.assertEquals(false, card.canRecalculate);
            System.assertEquals(false, card.canLogSignal);
        }
    }

    @IsTest
    static void csmSeesActionsAndCanUseThem() {
        User csm = userByAlias('riqcsm');
        Account account = createAccount('RIQ CSM Card');
        account.OwnerId = csm.Id;
        update account;

        System.runAs(csm) {
            Test.startTest();
            RIQ_AccountHealthController.HealthCard card = RIQ_AccountHealthController.getHealthCard(account.Id);
            Id signalId = RIQ_AccountHealthController.logSignal(
                account.Id,
                'Support Escalation',
                4,
                Date.today(),
                'CSM logged this from the record page.'
            );
            RIQ_AccountHealthController.HealthCard refreshed = RIQ_AccountHealthController.recalculate(account.Id);
            Test.stopTest();

            System.assertEquals(true, card.canRecalculate);
            System.assertEquals(true, card.canLogSignal);
            System.assertNotEquals(null, signalId);
            System.assert(refreshed.score < 42, 'A severe escalation must lower the score.');
        }
    }

    @IsTest
    static void recalculateRequiresTheCustomPermission() {
        User readOnly = userByAlias('riqro');
        Account account = createAccount('RIQ Recalc Denied');
        account.OwnerId = readOnly.Id;
        update account;

        System.runAs(readOnly) {
            Test.startTest();
            Boolean rejected = false;

            try {
                RIQ_AccountHealthController.recalculate(account.Id);
            } catch (AuraHandledException friendly) {
                rejected = true;
                System.assert(friendly.getMessage().contains('permission'));
            }

            Test.stopTest();
            System.assert(rejected, 'Read-only must not be able to force a recalculation.');
        }
    }

    @IsTest
    static void recalculateRejectsNullAndUnknownAccounts() {
        Test.startTest();
        Integer failures = 0;

        try {
            RIQ_AccountHealthController.recalculate(null);
        } catch (AuraHandledException expected) {
            failures++;
        }

        try {
            RIQ_AccountHealthController.recalculate('001000000000001AAA');
        } catch (AuraHandledException expected) {
            failures++;
        }

        Test.stopTest();
        System.assertEquals(2, failures);
    }

    @IsTest
    static void logSignalSavesTheRecord() {
        Account account = createAccount('RIQ Signal Saved');

        Test.startTest();
        Id signalId = RIQ_AccountHealthController.logSignal(
            account.Id,
            'Missed QBR',
            3,
            Date.today().addDays(-2),
            'QBR cancelled twice.'
        );
        Test.stopTest();

        RIQ_Health_Signal__c signal = [
            SELECT Account__c, Signal_Type__c, Severity__c, Occurred_On__c, Notes__c
            FROM RIQ_Health_Signal__c
            WHERE Id = :signalId
        ];

        System.assertEquals(account.Id, signal.Account__c);
        System.assertEquals('Missed QBR', signal.Signal_Type__c);
        System.assertEquals(3, signal.Severity__c.intValue());
        System.assertEquals(Date.today().addDays(-2), signal.Occurred_On__c);
        System.assertEquals('QBR cancelled twice.', signal.Notes__c);
    }

    @IsTest
    static void logSignalValidatesEveryInput() {
        Account account = createAccount('RIQ Signal Validation');

        Test.startTest();
        Integer rejections = 0;

        for (Integer severity : new List<Integer>{ 0, 6, null }) {
            try {
                RIQ_AccountHealthController.logSignal(account.Id, 'Missed QBR', severity, Date.today(), null);
            } catch (AuraHandledException expected) {
                rejections++;
            }
        }

        try {
            RIQ_AccountHealthController.logSignal(account.Id, 'Missed QBR', 3, Date.today().addDays(1), null);
        } catch (AuraHandledException expected) {
            rejections++;
        }

        try {
            RIQ_AccountHealthController.logSignal(account.Id, 'Missed QBR', 3, null, null);
        } catch (AuraHandledException expected) {
            rejections++;
        }

        try {
            RIQ_AccountHealthController.logSignal(account.Id, 'Not A Signal', 3, Date.today(), null);
        } catch (AuraHandledException expected) {
            rejections++;
        }

        try {
            RIQ_AccountHealthController.logSignal(null, 'Missed QBR', 3, Date.today(), null);
        } catch (AuraHandledException expected) {
            rejections++;
        }

        Test.stopTest();

        System.assertEquals(7, rejections, 'Every invalid input must be refused.');
        System.assertEquals(0, [SELECT COUNT() FROM RIQ_Health_Signal__c], 'Nothing may be written for rejected input.');
    }

    @IsTest
    static void logSignalRequiresTheCustomPermission() {
        User readOnly = userByAlias('riqro');
        Account account = createAccount('RIQ Signal Denied');
        account.OwnerId = readOnly.Id;
        update account;

        System.runAs(readOnly) {
            Test.startTest();
            Boolean rejected = false;

            try {
                RIQ_AccountHealthController.logSignal(account.Id, 'Missed QBR', 3, Date.today(), null);
            } catch (AuraHandledException friendly) {
                rejected = true;
                System.assert(friendly.getMessage().contains('permission'));
            }

            Test.stopTest();

            System.assert(rejected, 'Read-only must not be able to log signals.');
            System.assertEquals(0, [SELECT COUNT() FROM RIQ_Health_Signal__c]);
        }
    }

    @IsTest
    static void logSignalOnAnUnreachableAccountIsFriendly() {
        User csm = userByAlias('riqout');
        Account account = createAccount('RIQ Gone');
        Id accountId = account.Id;
        delete account;

        // A deleted id exercises the same branch as a record hidden by sharing:
        // the USER_MODE lookup returns nothing and the caller gets a friendly
        // message instead of a null-pointer insert.
        System.runAs(csm) {
            Test.startTest();
            Boolean rejected = false;

            try {
                RIQ_AccountHealthController.logSignal(accountId, 'Missed QBR', 3, Date.today(), null);
            } catch (AuraHandledException friendly) {
                rejected = true;
                System.assert(friendly.getMessage().contains('access'));
            }

            Test.stopTest();

            System.assert(rejected, 'A signal cannot be logged against a record the viewer cannot reach.');
            System.assertEquals(0, [SELECT COUNT() FROM RIQ_Health_Signal__c]);
        }
    }

    @IsTest
    static void signalTypesComeFromThePicklist() {
        Test.startTest();
        List<String> types = RIQ_AccountHealthController.getSignalTypes();
        Test.stopTest();

        System.assert(types.size() >= 4, 'The logger needs the deployed picklist values.');
        System.assert(types.contains('Support Escalation'));
    }

    @IsTest
    static void driverParserHandlesEveryGarbageShape() {
        Test.startTest();
        System.assertEquals(0, RIQ_AccountHealthController.parseDrivers(null).size());
        System.assertEquals(0, RIQ_AccountHealthController.parseDrivers('').size());
        System.assertEquals(0, RIQ_AccountHealthController.parseDrivers('[]').size());
        System.assertEquals(0, RIQ_AccountHealthController.parseDrivers('{"signalType":"x"}').size());
        System.assertEquals(0, RIQ_AccountHealthController.parseDrivers('[1,2,3]').size());
        System.assertEquals(2, RIQ_AccountHealthController.parseDrivers(VALID_DRIVERS).size());
        Test.stopTest();
    }

    /**
     * @description The button spends money at the model provider, so the right to
     * press it is a Custom Permission checked in Apex. A Read-Only user calling
     * the method directly (which is what hiding a button does not stop) is refused.
     */
    @IsTest
    static void generateInsightRequiresTheCustomPermission() {
        Account account = createAccount('RIQ Insight Permission');
        User readOnly = userByAlias('riqro');

        Test.startTest();
        Boolean refused = false;
        System.runAs(readOnly) {
            try {
                RIQ_AccountHealthController.generateInsight(account.Id);
            } catch (AuraHandledException friendly) {
                refused = true;
                System.assert(friendly.getMessage().contains('permission'), 'The message explains the refusal.');
            }
        }
        Test.stopTest();

        System.assert(refused, 'A Read-Only user must not be able to generate insights.');
        Account untouched = [SELECT RIQ_AI_Summary__c FROM Account WHERE Id = :account.Id];
        System.assertEquals(null, untouched.RIQ_AI_Summary__c);
    }

    /**
     * @description With the shipped configuration (disabled) and no API key, the
     * button still produces something useful: a rule-based insight written to the
     * account, with the source recorded so it cannot be mistaken for a model answer.
     */
    @IsTest
    static void generateInsightFallsBackToRulesWithoutAKey() {
        Account account = createAccount('RIQ Insight Rules');
        addHistory(account.Id, 42, 'At Risk', DateTime.now(), VALID_DRIVERS);
        User csm = userByAlias('riqcsm');

        Test.startTest();
        RIQ_AccountHealthController.HealthCard card;
        System.runAs(csm) {
            card = RIQ_AccountHealthController.generateInsight(account.Id);
        }
        Test.stopTest();

        System.assertEquals('Rule-based', card.aiSource);
        System.assertEquals('Rule-based', card.canGenerateInsight ? card.aiSource : null);
        System.assert(String.isNotBlank(card.aiSummary));
        System.assert(String.isNotBlank(card.nextBestAction));
        System.assertNotEquals(null, card.aiGeneratedOn);
        System.assert(card.aiRiskReasons.size() > 0, 'The fallback names at least one reason.');

        Account stored = [
            SELECT RIQ_AI_Summary__c, RIQ_AI_Source__c, RIQ_AI_Generated_On__c
            FROM Account
            WHERE Id = :account.Id
        ];
        System.assert(String.isNotBlank(stored.RIQ_AI_Summary__c), 'The insight is persisted on the account.');
        System.assertEquals('Rule-based', stored.RIQ_AI_Source__c);
    }

    /**
     * @description The card must expose the stored insight so the component can
     * render it without a second request.
     */
    @IsTest
    static void cardExposesTheStoredInsight() {
        Account account = createAccount('RIQ Insight Card');
        account.RIQ_AI_Summary__c = 'Stored summary.';
        account.RIQ_Next_Best_Action__c = 'Stored action.';
        account.RIQ_AI_Risk_Reasons__c = 'Reason one\nReason two\n\n';
        account.RIQ_AI_Source__c = 'AI';
        account.RIQ_AI_Generated_On__c = DateTime.now();
        update account;

        Test.startTest();
        RIQ_AccountHealthController.HealthCard card = RIQ_AccountHealthController.getHealthCard(account.Id);
        Test.stopTest();

        System.assertEquals('Stored summary.', card.aiSummary);
        System.assertEquals('Stored action.', card.nextBestAction);
        System.assertEquals('AI', card.aiSource);
        System.assertEquals(2, card.aiRiskReasons.size(), 'Blank lines are dropped.');
        System.assertNotEquals(null, card.aiGeneratedOn);
    }

    @IsTest
    static void generateInsightRejectsANullAccount() {
        Test.startTest();
        Boolean rejected = false;

        try {
            RIQ_AccountHealthController.generateInsight(null);
        } catch (AuraHandledException friendly) {
            rejected = true;
        }

        Test.stopTest();
        System.assert(rejected);
    }

    @IsTest
    static void generateInsightRejectsAnUnknownAccount() {
        Test.startTest();
        Boolean rejected = false;

        try {
            RIQ_AccountHealthController.generateInsight('001000000000001AAA');
        } catch (AuraHandledException friendly) {
            rejected = true;
            System.assert(friendly.getMessage().contains('not exist'), 'The message explains the miss.');
        }

        Test.stopTest();
        System.assert(rejected);
    }
}
