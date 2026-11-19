/**
 * @description Proves the two promises RIQ_Logger makes: the line is stored even
 * though the publishing transaction is not the one that writes it, and nothing
 * secret or personal reaches the field.
 */
@IsTest
private class RIQ_Logger_Test {
    /**
     * @return A real exception instance, because Apex exception constructors are
     *         not reliably callable from a test.
     */
    private static Exception realFailure() {
        try {
            Integer impossible = 1 / 0;
            System.debug(impossible); // NOPMD a deliberate divide by zero, so the debug is the least of it
        } catch (Exception caught) {
            return caught;
        }

        return null;
    }

    @IsTest
    static void storesAnErrorThroughThePlatformEvent() {
        Test.startTest();
        RIQ_Logger.error(
            'RIQ_Logger_Test',
            'Callout failed for gsk_abcdefghijklmnop and a.person@example.com.',
            realFailure(),
            String.valueOf(RIQ_TestDataFactory.nonExistentAccountId())
        );
        Test.stopTest();

        List<RIQ_Log__c> rows = [
            SELECT Level__c, Source__c, Message__c, Stack_Trace__c, Related_Id__c, Logged_At__c
            FROM RIQ_Log__c
        ];

        Assert.areEqual(1, rows.size(), 'The published line should have been stored by the subscriber trigger.');
        RIQ_Log__c row = rows[0];
        Assert.areEqual(RIQ_Logger.LEVEL_ERROR, row.Level__c);
        Assert.areEqual('RIQ_Logger_Test', row.Source__c);
        Assert.areEqual(String.valueOf(RIQ_TestDataFactory.nonExistentAccountId()), row.Related_Id__c);
        Assert.isNotNull(row.Logged_At__c, 'Logged At should carry the original time.');
        Assert.isNotNull(row.Stack_Trace__c, 'An error should carry its exception type.');
        Assert.isFalse(row.Message__c.contains('gsk_'), 'A provider key must never be stored.');
        Assert.isFalse(row.Message__c.contains('example.com'), 'An email address must never be stored.');
        Assert.isTrue(row.Message__c.contains('[redacted key]'), 'The key should be visibly redacted.');
    }

    @IsTest
    static void storesWarningsAndInformation() {
        Test.startTest();
        RIQ_Logger.warn('RIQ_Logger_Test', 'A handled condition.');
        RIQ_Logger.warn('RIQ_Logger_Test', 'A handled condition with an exception.', realFailure());
        RIQ_Logger.info('RIQ_Logger_Test', 'A routine fact.');
        RIQ_Logger.info(
            'RIQ_Logger_Test',
            'A routine fact about a job.',
            String.valueOf(RIQ_TestDataFactory.nonExistentAccountId())
        );
        Test.stopTest();

        String warningLevel = RIQ_Logger.LEVEL_WARNING;
        String infoLevel = RIQ_Logger.LEVEL_INFO;

        Assert.areEqual(2, [SELECT COUNT() FROM RIQ_Log__c WHERE Level__c = :warningLevel]);
        Assert.areEqual(2, [SELECT COUNT() FROM RIQ_Log__c WHERE Level__c = :infoLevel]);
    }

    @IsTest
    static void redactsTokensAndPersonalData() {
        String cleaned = RIQ_Logger.redactSecrets(
            'Authorization: Bearer abcdef123456 apiKey=supersecret phone +91 98765 43210 claim 0000000000',
            255
        );

        Assert.isFalse(cleaned.contains('abcdef123456'), 'A bearer token must be redacted.');
        Assert.isFalse(cleaned.contains('supersecret'), 'An assigned secret must be redacted.');
        Assert.isFalse(cleaned.contains('98765'), 'A phone number must be redacted.');
        Assert.isFalse(cleaned.contains('0000000000'), 'A long number must be redacted.');
        Assert.isTrue(cleaned.contains('[redacted token]'));
        Assert.isTrue(cleaned.contains('[redacted number]'));
    }

    @IsTest
    static void truncatesToThePlatformEventLimit() {
        String longMessage = 'x'.repeat(600);
        String cleaned = RIQ_Logger.redactSecrets(longMessage, RIQ_Logger.MAX_MESSAGE_LENGTH);

        Assert.areEqual(RIQ_Logger.MAX_MESSAGE_LENGTH, cleaned.length(), 'The payload must fit the event field.');
    }

    @IsTest
    static void keepsNullsAndShortTextUntouched() {
        Assert.isNull(RIQ_Logger.redactSecrets(null, 255));
        Assert.areEqual('', RIQ_Logger.redactSecrets('', 255));
        Assert.areEqual('Nothing to see here.', RIQ_Logger.redactSecrets('Nothing to see here.', 255));
    }

    @IsTest
    static void persistsAnEventDirectly() {
        Test.startTest();
        RIQ_Logger.persist(
            new List<RIQ_Log_Event__e>{
                new RIQ_Log_Event__e(
                    Level__c = RIQ_Logger.LEVEL_INFO,
                    Source__c = 'RIQ_Logger_Test',
                    Message__c = 'Mapped straight from an event.',
                    Stack_Trace__c = null,
                    Related_Id__c = String.valueOf(RIQ_TestDataFactory.nonExistentAccountId()),
                    Logged_At__c = DateTime.now().addDays(-1)
                )
            }
        );
        RIQ_Logger.persist(new List<RIQ_Log_Event__e>());
        RIQ_Logger.persist(null);
        Test.stopTest();

        RIQ_Log__c row = [SELECT Message__c, Related_Id__c, Logged_At__c FROM RIQ_Log__c LIMIT 1];
        Assert.areEqual('Mapped straight from an event.', row.Message__c);
        Assert.areEqual(String.valueOf(RIQ_TestDataFactory.nonExistentAccountId()), row.Related_Id__c);
        Assert.isNotNull(row.Logged_At__c);
    }
}
