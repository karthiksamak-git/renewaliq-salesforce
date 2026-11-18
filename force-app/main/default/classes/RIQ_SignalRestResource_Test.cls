@IsTest
private class RIQ_SignalRestResource_Test {
    private static final String SIGNAL_TYPE = 'Support Escalation';

    /**
     * @description Users and permission set assignments are setup-object DML and
     * cannot share a transaction with Account DML, so they are created here, in
     * the separate @TestSetup transaction.
     */
    @TestSetup
    static void createUsers() {
        RIQ_TestDataFactory.createUserWithPermissionSets('riqapi', new List<String>{ 'RIQ_Integration_User' });
        RIQ_TestDataFactory.createUserWithPermissionSets('riqout', new List<String>());
    }

    /**
     * @param alias Alias used when the user was created.
     * @return The test user.
     */
    private static User userByAlias(String alias) {
        return [SELECT Id, Alias FROM User WHERE Alias = :alias LIMIT 1];
    }


    /**
     * @param body Raw request body.
     * @return The REST response.
     */
    private static RestResponse post(String body) {
        RestRequest request = new RestRequest();
        request.requestUri = '/services/apexrest/riq/v1/signals';
        request.httpMethod = 'POST';
        request.requestBody = Blob.valueOf(body);
        RestContext.request = request;
        RestContext.response = new RestResponse();

        RIQ_SignalRestResource.doPost();
        return RestContext.response;
    }

    /**
     * @param response REST response.
     * @return Parsed envelope.
     */
    private static RIQ_SignalRestResource.ApiResponse payload(RestResponse response) {
        return (RIQ_SignalRestResource.ApiResponse) JSON.deserialize(
            response.responseBody.toString(),
            RIQ_SignalRestResource.ApiResponse.class
        );
    }

    /**
     * @param externalId Idempotency key.
     * @param accountId Account to attach to.
     * @param signalType Picklist value.
     * @param occurredOn Date string.
     * @return One request object.
     */
    private static Map<String, Object> item(String externalId, String accountId, String signalType, String occurredOn) {
        return new Map<String, Object>{
            'externalId' => externalId,
            'accountId' => accountId,
            'signalType' => signalType,
            'severity' => 3,
            'occurredOn' => occurredOn
        };
    }

    /**
     * @param count Accounts to create.
     * @return Inserted accounts.
     */
    private static List<Account> accounts(Integer count) {
        List<Account> created = new List<Account>();

        for (Integer i = 0; i < count; i++) {
            created.add(
                new Account(
                    Name = 'RIQ REST ' + DateTime.now().getTime() + '-' + i,
                    AccountNumber = 'RIQ-' + DateTime.now().getTime() + '-' + i
                )
            );
        }

        insert created;
        return created;
    }

    @IsTest
    static void singleSignalIsCreatedAndQueuesARecalculation() {
        Account account = accounts(1)[0];
        String body = JSON.serialize(
            new List<Object>{ item('ext-single-1', account.Id, SIGNAL_TYPE, String.valueOf(Date.today())) }
        );

        Test.startTest();
        RestResponse response = post(body);
        Test.stopTest();

        System.assertEquals(200, response.statusCode);
        RIQ_SignalRestResource.ApiResponse parsed = payload(response);
        System.assertEquals(1, parsed.created);
        System.assertEquals(0, parsed.failed);
        System.assertEquals('created', parsed.results[0].status);

        List<RIQ_Health_Signal__c> stored = [
            SELECT Id, RIQ_External_Key__c, Account__c, Signal_Type__c
            FROM RIQ_Health_Signal__c
            WHERE RIQ_External_Key__c = 'ext-single-1'
        ];
        System.assertEquals(1, stored.size());
        System.assertEquals(account.Id, stored[0].Account__c);

        Account rescored = [SELECT RIQ_Last_Scored__c, RIQ_Health_Status__c FROM Account WHERE Id = :account.Id];
        System.assertNotEquals(null, rescored.RIQ_Last_Scored__c, 'The signal trigger queues the existing recalculation.');
    }

    @IsTest
    static void retryUpdatesInsteadOfDuplicating() {
        Account account = accounts(1)[0];
        String body = JSON.serialize(
            new List<Object>{ item('ext-retry-1', account.Id, SIGNAL_TYPE, String.valueOf(Date.today())) }
        );

        Test.startTest();
        post(body);
        RestResponse second = post(body);
        Test.stopTest();

        RIQ_SignalRestResource.ApiResponse parsed = payload(second);
        System.assertEquals(200, second.statusCode);
        System.assertEquals(0, parsed.created);
        System.assertEquals(1, parsed.updated);
        System.assertEquals('updated', parsed.results[0].status);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM RIQ_Health_Signal__c WHERE RIQ_External_Key__c = 'ext-retry-1'],
            'An idempotent retry must not create a second signal.'
        );
    }

    @IsTest
    static void duplicateKeyInOnePayloadUsesTheLastOccurrence() {
        Account account = accounts(1)[0];
        String body = JSON.serialize(
            new List<Object>{
                item('ext-dup-1', account.Id, SIGNAL_TYPE, String.valueOf(Date.today())),
                item('ext-dup-1', account.Id, 'Missed QBR', String.valueOf(Date.today()))
            }
        );

        Test.startTest();
        RestResponse response = post(body);
        Test.stopTest();

        RIQ_SignalRestResource.ApiResponse parsed = payload(response);
        System.assertEquals('skipped', parsed.results[0].status);
        System.assertEquals('created', parsed.results[1].status);
        System.assertEquals(1, [SELECT COUNT() FROM RIQ_Health_Signal__c WHERE RIQ_External_Key__c = 'ext-dup-1']);
        System.assertEquals(
            'Missed QBR',
            [SELECT Signal_Type__c FROM RIQ_Health_Signal__c WHERE RIQ_External_Key__c = 'ext-dup-1'].Signal_Type__c
        );
    }

    @IsTest
    static void invalidRowsAreReportedWithoutFailingTheGoodOnes() {
        Account account = accounts(1)[0];
        String future = String.valueOf(Date.today().addDays(3));
        List<Object> items = new List<Object>{
            item('ext-good-1', account.Id, SIGNAL_TYPE, String.valueOf(Date.today())),
            item('ext-bad-type', account.Id, 'Not A Real Type', String.valueOf(Date.today())),
            item('ext-bad-date', account.Id, SIGNAL_TYPE, future),
            item('ext-bad-account', String.valueOf(RIQ_TestDataFactory.nonExistentAccountId()), SIGNAL_TYPE, String.valueOf(Date.today())),
            new Map<String, Object>{ 'accountId' => account.Id, 'signalType' => SIGNAL_TYPE, 'severity' => 3 },
            item('ext-bad-severity', account.Id, SIGNAL_TYPE, String.valueOf(Date.today()))
        };
        ((Map<String, Object>) items[5]).put('severity', 9);

        Test.startTest();
        RestResponse response = post(JSON.serialize(items));
        Test.stopTest();

        RIQ_SignalRestResource.ApiResponse parsed = payload(response);
        System.assertEquals(200, response.statusCode, 'Partial success is a 200 with per-row detail.');
        System.assertEquals(1, parsed.created);
        System.assertEquals(5, parsed.failed);
        System.assertEquals('error', parsed.results[1].status);
        System.assert(parsed.results[1].message.contains('not a known signal type'));
        System.assert(parsed.results[2].message.contains('future'));
        System.assert(parsed.results[3].message.contains('No account matches'));
        System.assert(parsed.results[4].message.contains('externalId is required'));
        System.assert(parsed.results[5].message.contains('severity'));
    }

    @IsTest
    static void accountNumberResolvesAsExternalReference() {
        Account account = accounts(1)[0];
        Map<String, Object> entry = item('ext-number-1', null, SIGNAL_TYPE, String.valueOf(Date.today()));
        entry.put('accountExternalId', account.AccountNumber);

        Test.startTest();
        RestResponse response = post(JSON.serialize(new List<Object>{ entry }));
        Test.stopTest();

        RIQ_SignalRestResource.ApiResponse parsed = payload(response);
        System.assertEquals(1, parsed.created);
        System.assertEquals(
            account.Id,
            [SELECT Account__c FROM RIQ_Health_Signal__c WHERE RIQ_External_Key__c = 'ext-number-1'].Account__c
        );
    }

    @IsTest
    static void malformedAndOversizedBodiesAreRejected() {
        Test.startTest();
        RestResponse notJson = post('{not json');
        RestResponse notArray = post('{"externalId":"x"}');
        RestResponse empty = post('');
        Test.stopTest();

        System.assertEquals(400, notJson.statusCode);
        System.assertEquals(400, notArray.statusCode);
        System.assertEquals(400, empty.statusCode);
        System.assert(payload(notJson).results[0].message.contains('not valid JSON'));

        List<Object> tooMany = new List<Object>();
        for (Integer i = 0; i <= RIQ_SignalRestResource.MAX_SIGNALS; i++) {
            tooMany.add(item('ext-over-' + i, String.valueOf(RIQ_TestDataFactory.nonExistentAccountId()), SIGNAL_TYPE, String.valueOf(Date.today())));
        }

        RestResponse oversized = post(JSON.serialize(tooMany));
        System.assertEquals(413, oversized.statusCode);
        System.assert(payload(oversized).results[0].message.contains('maximum of 200'));
    }

    @IsTest
    static void twoHundredSignalsAreHandledInOnePass() {
        List<Account> owners = accounts(5);
        List<Object> items = new List<Object>();

        for (Integer i = 0; i < 200; i++) {
            items.add(item('ext-bulk-' + i, owners[Math.mod(i, owners.size())].Id, SIGNAL_TYPE, String.valueOf(Date.today())));
        }

        Test.startTest();
        RestResponse response = post(JSON.serialize(items));
        Test.stopTest();

        RIQ_SignalRestResource.ApiResponse parsed = payload(response);
        System.assertEquals(200, parsed.created);
        System.assertEquals(0, parsed.failed);
        System.assertEquals(200, [SELECT COUNT() FROM RIQ_Health_Signal__c WHERE RIQ_External_Key__c LIKE 'ext-bulk-%']);
    }

    @IsTest
    static void integrationUserCanPostWithOnlyItsPermissionSet() {
        User integrationUser = userByAlias('riqapi');
        Account account = accounts(1)[0];

        Test.startTest();
        System.runAs(integrationUser) {
            // "Today" has to be the caller's today: Date.today() follows the running
            // user's time zone, and this user is not the one who created the account.
            // Building the body outside the runAs made the test fail only in the
            // window where IST and the user's zone are on different calendar days.
            String body = JSON.serialize(
                new List<Object>{ item('ext-runas-1', account.Id, SIGNAL_TYPE, String.valueOf(Date.today())) }
            );
            RestResponse response = post(body);
            System.assertEquals(200, response.statusCode);
            System.assertEquals(1, payload(response).created, response.responseBody.toString());
        }
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM RIQ_Health_Signal__c WHERE RIQ_External_Key__c = 'ext-runas-1']);
    }

    @IsTest
    static void userWithoutThePermissionSetIsRefused() {
        User outsider = userByAlias('riqout');
        Account account = accounts(1)[0];
        String body = JSON.serialize(
            new List<Object>{ item('ext-outsider-1', account.Id, SIGNAL_TYPE, String.valueOf(Date.today())) }
        );

        Test.startTest();
        System.runAs(outsider) {
            // USER_MODE DML refuses the insert, and the row is reported as an
            // error instead of throwing a 500 at the caller.
            RestResponse response = post(body);
            System.assertEquals(200, response.statusCode);
            System.assertEquals(1, payload(response).failed);
        }
        Test.stopTest();
    }

    @IsTest
    static void missingContextIsHandledDefensively() {
        RestContext.request = null;
        RestContext.response = null;

        Test.startTest();
        RIQ_SignalRestResource.doPost();
        Test.stopTest();

        System.assertNotEquals(null, RestContext.response, 'A response is always produced.');
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @IsTest
    static void structurallyInvalidItemsAreRejected() {
        Account account = accounts(1)[0];
        List<Object> items = new List<Object>{
            'just a string',
            new Map<String, Object>{
                'externalId' => 'x'.repeat(130),
                'accountId' => account.Id,
                'signalType' => SIGNAL_TYPE,
                'severity' => 3,
                'occurredOn' => String.valueOf(Date.today())
            },
            new Map<String, Object>{
                'externalId' => 'ext-bad-id',
                'accountId' => 'not-an-id',
                'signalType' => SIGNAL_TYPE,
                'severity' => 3,
                'occurredOn' => String.valueOf(Date.today())
            },
            new Map<String, Object>{
                'externalId' => 'ext-no-date',
                'accountId' => account.Id,
                'signalType' => SIGNAL_TYPE,
                'severity' => 3
            },
            new Map<String, Object>{
                'externalId' => 'ext-no-account',
                'signalType' => SIGNAL_TYPE,
                'severity' => 3,
                'occurredOn' => String.valueOf(Date.today())
            },
            new Map<String, Object>{
                'externalId' => 'ext-long-notes',
                'accountId' => account.Id,
                'signalType' => SIGNAL_TYPE,
                'severity' => 3,
                'occurredOn' => String.valueOf(Date.today()),
                'notes' => 'n'.repeat(RIQ_SignalRestResource.MAX_NOTES_LENGTH + 1)
            }
        };

        Test.startTest();
        RestResponse response = post(JSON.serialize(items));
        Test.stopTest();

        RIQ_SignalRestResource.ApiResponse parsed = payload(response);
        System.assertEquals(200, response.statusCode);
        System.assertEquals(0, parsed.created);
        System.assertEquals(6, parsed.failed);
    }

    @IsTest
    static void databaseFailuresAreReportedPerRow() {
        Account account = accounts(1)[0];
        // Notes__c is a 1000 character field; 1200 characters pass REST validation
        // and must fail at DML, where the error is caught and reported per row.
        Map<String, Object> entry = item('ext-dml-1', account.Id, SIGNAL_TYPE, String.valueOf(Date.today()));
        entry.put('notes', 'n'.repeat(1200));

        Test.startTest();
        RestResponse response = post(JSON.serialize(new List<Object>{ entry }));
        Test.stopTest();

        RIQ_SignalRestResource.ApiResponse parsed = payload(response);
        System.assertEquals(200, response.statusCode);
        System.assertEquals('error', parsed.results[0].status);
        System.assert(String.isNotBlank(parsed.results[0].message));
    }
}
