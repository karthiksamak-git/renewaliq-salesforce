/**
 * @description Persona audit: what an Administrator, a CSM, a Read-Only viewer,
 * the Integration user and an AI-insight user can and cannot do.
 *
 * Every assertion calls the real entry point as that user. Hiding a button is
 * not access control, so the negative cases go straight at the Apex method and
 * expect a friendly refusal rather than a silently successful write.
 *
 * Accounts are owned by the persona under test. Ownership is what makes the row
 * visible without depending on the org's account sharing model, which is a
 * deployment setting this test must not assume.
 *
 * The users live in @TestSetup on purpose: User and PermissionSetAssignment are
 * setup objects, and a transaction cannot mix setup DML with Account DML
 * (MIXED_DML_OPERATION). @TestSetup runs in its own transaction.
 */
@IsTest
private class RIQ_SecurityModel_Test {
    @TestSetup
    static void createPersonas() {
        RIQ_TestDataFactory.createUserWithPermissionSets('riqro', new List<String>{ 'RIQ_Read_Only' });
        RIQ_TestDataFactory.createUserWithPermissionSets('riqro2', new List<String>{ 'RIQ_Read_Only' });
        RIQ_TestDataFactory.createUserWithPermissionSets('riqcsm', new List<String>{ 'RIQ_CSM' });
        RIQ_TestDataFactory.createUserWithPermissionSets('riqcsm2', new List<String>{ 'RIQ_CSM' });
        RIQ_TestDataFactory.createUserWithPermissionSets('riqint', new List<String>{ 'RIQ_Integration_User' });
        RIQ_TestDataFactory.createUserWithPermissionSets(
            'riqai',
            new List<String>{ 'RIQ_Read_Only', 'RIQ_AI_Insight' }
        );
        RIQ_TestDataFactory.createUserWithPermissionSets('riqadm', new List<String>{ 'RIQ_Admin' });
    }

    /**
     * @param alias Alias the persona was created with.
     * @return The test user.
     */
    private static User persona(String alias) {
        return [SELECT Id FROM User WHERE Alias = :alias LIMIT 1];
    }

    /**
     * @param ownerId Owner of the new account.
     * @return An account the persona can see because they own it.
     */
    private static Account createAccountFor(Id ownerId) {
        Account account = new Account(
            Name = 'RIQ Security Account',
            OwnerId = ownerId,
            RIQ_ARR__c = 2500000,
            RIQ_Contract_End_Date__c = Date.today().addDays(60)
        );

        insert account;
        return account;
    }

    @IsTest
    static void readOnlyUserReadsButCannotChangeAnything() {
        User viewer = persona('riqro');
        Account account = createAccountFor(viewer.Id);

        Test.startTest();
        System.runAs(viewer) {
            RIQ_AccountHealthController.HealthCard card = RIQ_AccountHealthController.getHealthCard(account.Id);
            Assert.areEqual(account.Id, card.accountId, 'A read-only user must be able to read their own account.');
            Assert.isFalse(card.canRecalculate, 'A read-only user must not be offered recalculate.');
            Assert.isFalse(card.canLogSignal, 'A read-only user must not be offered the signal logger.');
            Assert.isFalse(card.canGenerateInsight, 'A read-only user must not be offered the AI button.');

            try {
                RIQ_AccountHealthController.recalculate(account.Id);
                Assert.fail('A read-only user must not be able to recalculate.');
            } catch (AuraHandledException expected) {
                Assert.isTrue(
                    expected.getMessage().contains('permission'),
                    'The refusal must say why: ' + expected.getMessage()
                );
            }

            try {
                RIQ_AccountHealthController.logSignal(
                    account.Id,
                    'Support Escalation',
                    4,
                    Date.today().addDays(-1),
                    'note'
                );
                Assert.fail('A read-only user must not be able to log a signal.');
            } catch (AuraHandledException expected) {
                Assert.isTrue(
                    expected.getMessage().contains('permission'),
                    'The refusal must say why: ' + expected.getMessage()
                );
            }

            try {
                RIQ_AccountHealthController.generateInsight(account.Id);
                Assert.fail('A read-only user must not be able to spend a model call.');
            } catch (AuraHandledException expected) {
                Assert.isTrue(
                    expected.getMessage().contains('permission'),
                    'The refusal must say why: ' + expected.getMessage()
                );
            }
        }
        Test.stopTest();

        Assert.areEqual(
            0,
            [SELECT COUNT() FROM RIQ_Health_Signal__c],
            'A refused call must not have written a signal.'
        );
    }

    @IsTest
    static void readOnlyUserCannotWriteASignalEvenWithDirectDml() {
        User viewer = persona('riqro2');
        Account account = createAccountFor(viewer.Id);

        Test.startTest();
        System.runAs(viewer) {
            try {
                Database.insert(
                    new RIQ_Health_Signal__c(
                        Account__c = account.Id,
                        Signal_Type__c = 'Support Escalation',
                        Severity__c = 5,
                        Occurred_On__c = Date.today()
                    ),
                    AccessLevel.USER_MODE
                );
                Assert.fail('USER_MODE DML must refuse a create this user has no permission for.');
            } catch (Exception expected) {
                // A user with no create permission is refused before DML starts;
                // one with create but no field access fails inside it. Both are
                // the right outcome, so the assertion is on the reason.
                Assert.isTrue(
                    expected.getMessage().toLowerCase().contains('not allowed') ||
                    expected.getMessage().toLowerCase().contains('insufficient access'),
                    'The platform should refuse on permissions: ' + expected.getMessage()
                );
            }
        }
        Test.stopTest();
    }

    @IsTest
    static void csmCanRecalculateAndLogASignal() {
        User csm = persona('riqcsm');
        Account account = createAccountFor(csm.Id);

        Test.startTest();
        System.runAs(csm) {
            RIQ_AccountHealthController.HealthCard card = RIQ_AccountHealthController.getHealthCard(account.Id);
            Assert.isTrue(card.canRecalculate, 'A CSM should be offered recalculate.');
            Assert.isTrue(card.canLogSignal, 'A CSM should be offered the signal logger.');

            RIQ_AccountHealthController.HealthCard recalculated = RIQ_AccountHealthController.recalculate(account.Id);
            Assert.isNotNull(recalculated.score, 'Recalculating should produce a score.');

            Id signalId = RIQ_AccountHealthController.logSignal(
                account.Id,
                'Support Escalation',
                4,
                Date.today().addDays(-1),
                'Escalated to the support lead.'
            );
            Assert.isNotNull(signalId, 'A CSM may log a signal.');
        }
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM RIQ_Health_Signal__c], 'Exactly one signal should exist.');
    }

    @IsTest
    static void csmCannotBypassTheNotesLimit() {
        User csm = persona('riqcsm2');
        Account account = createAccountFor(csm.Id);

        Test.startTest();
        System.runAs(csm) {
            try {
                RIQ_AccountHealthController.logSignal(
                    account.Id,
                    'Support Escalation',
                    4,
                    Date.today().addDays(-1),
                    'x'.repeat(5001)
                );
                Assert.fail('Notes longer than the field must be refused before DML.');
            } catch (AuraHandledException expected) {
                Assert.isTrue(expected.getMessage().contains('too long'), 'The refusal must be understandable.');
            }
        }
        Test.stopTest();
    }

    @IsTest
    static void integrationUserCanPostOneSignalAndNothingElse() {
        User integration = persona('riqint');
        Account account = createAccountFor(integration.Id);

        Test.startTest();
        System.runAs(integration) {
            RestRequest request = new RestRequest();
            request.requestURI = '/services/apexrest/riq/v1/signals/';
            request.httpMethod = 'POST';
            request.requestBody = Blob.valueOf(
                JSON.serialize(
                    new List<Object>{
                        new Map<String, Object>{
                            'externalId' => 'SEC-TEST-1',
                            'accountId' => account.Id,
                            'signalType' => 'Support Escalation',
                            'severity' => 4,
                            'occurredOn' => String.valueOf(Date.today().addDays(-2))
                        }
                    }
                )
            );
            RestContext.request = request;
            RestContext.response = new RestResponse();

            RIQ_SignalRestResource.doPost();

            Assert.areEqual(200, RestContext.response.statusCode, 'The integration user may post signals.');
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
                RestContext.response.responseBody.toString()
            );
            Assert.areEqual(1, body.get('created'), 'The signal should have been created: ' + body);

            try {
                RIQ_AccountHealthController.recalculate(account.Id);
                Assert.fail('An integration user must not be able to recalculate.');
            } catch (AuraHandledException expected) {
                Assert.isTrue(expected.getMessage().contains('permission'));
            }

            try {
                RIQ_AccountHealthController.generateInsight(account.Id);
                Assert.fail('An integration user must not be able to spend a model call.');
            } catch (AuraHandledException expected) {
                Assert.isTrue(expected.getMessage().contains('permission'));
            }
        }
        Test.stopTest();
    }

    @IsTest
    static void anAiInsightUserIsNotAutomaticallyACsm() {
        User analyst = persona('riqai');
        Account account = createAccountFor(analyst.Id);

        Test.startTest();
        System.runAs(analyst) {
            RIQ_AccountHealthController.HealthCard card = RIQ_AccountHealthController.getHealthCard(account.Id);
            Assert.isTrue(card.canGenerateInsight, 'The AI permission set should unlock the insight.');
            Assert.isFalse(card.canRecalculate, 'The AI permission set must not unlock recalculate.');
            Assert.isFalse(card.canLogSignal, 'The AI permission set must not unlock the signal logger.');

            // The model cannot be called from a test, so the service falls back
            // to rules. What is being proven is that the permission boundary let
            // the call through and that the stored result is honest about its
            // source.
            RIQ_AccountHealthController.HealthCard generated = RIQ_AccountHealthController.generateInsight(account.Id);
            Assert.areEqual(
                RIQ_AiInsightService.SOURCE_RULE_BASED,
                generated.aiSource,
                'Without a callout the source must be Rule-based.'
            );
            Assert.isTrue(
                String.isNotBlank(generated.aiSummary),
                'The rule-based insight must still explain the account.'
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void administratorCanDoEverything() {
        User admin = persona('riqadm');
        Account account = createAccountFor(admin.Id);

        Test.startTest();
        System.runAs(admin) {
            RIQ_AccountHealthController.HealthCard card = RIQ_AccountHealthController.getHealthCard(account.Id);
            Assert.isTrue(
                card.canRecalculate && card.canLogSignal && card.canGenerateInsight,
                'An administrator holds every custom permission.'
            );

            RIQ_AccountHealthController.recalculate(account.Id);
            RIQ_AccountHealthController.logSignal(
                account.Id,
                'Missed QBR',
                3,
                Date.today().addDays(-3),
                'Quarterly review slipped.'
            );
            RIQ_AccountHealthController.generateInsight(account.Id);

            Assert.areEqual(1, [SELECT COUNT() FROM RIQ_Health_Signal__c], 'The administrator may log a signal.');
        }
        Test.stopTest();
    }
}
