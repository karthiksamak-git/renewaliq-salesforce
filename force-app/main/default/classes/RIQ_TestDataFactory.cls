/**
 * @description Shared test data for RenewalIQ. Two kinds of helper live here:
 * builders that return unsaved records (for pure engine tests) and creators that
 * insert (for trigger and selector tests).
 *
 * Names are made unique per transaction so tests never collide on the org's
 * duplicate rules, and nothing is hardcoded to a particular org's data.
 */
@IsTest
public class RIQ_TestDataFactory {
    public static final String SUPPORT_ESCALATION = 'Support Escalation';
    public static final String LOW_PRODUCT_USAGE = 'Low Product Usage';
    public static final String MISSED_QBR = 'Missed QBR';
    public static final String POSITIVE_EXPANSION = 'Positive Expansion';
    public static final String LATE_PAYMENT = 'Late Payment';

    /**
     * @param count How many accounts to create.
     * @return Inserted accounts with distinct names, ARR and renewal dates.
     */
    public static List<Account> createAccounts(Integer count) {
        List<Account> accounts = new List<Account>();
        String uniqueSuffix = String.valueOf(DateTime.now().getTime());

        for (Integer i = 0; i < count; i++) {
            accounts.add(
                new Account(
                    Name = 'RenewalIQ Test ' + uniqueSuffix + '-' + i,
                    RIQ_ARR__c = 25000 + (i * 500),
                    RIQ_Contract_End_Date__c = Date.today().addDays(120 + i)
                )
            );
        }

        insert accounts;
        return accounts;
    }

    /**
     * @param accountId Parent account; may be null for in-memory tests.
     * @param signalType Picklist value.
     * @param severity Severity 1..5.
     * @param occurredOn Date the signal occurred.
     * @return An unsaved signal.
     */
    public static RIQ_Health_Signal__c buildSignal(Id accountId, String signalType, Integer severity, Date occurredOn) {
        return new RIQ_Health_Signal__c(
            Account__c = accountId,
            Signal_Type__c = signalType,
            Severity__c = severity,
            Occurred_On__c = occurredOn
        );
    }

    /**
     * @param accounts Accounts to attach signals to.
     * @param signalType Picklist value.
     * @param severity Severity 1..5.
     * @param occurredOn Date the signal occurred.
     * @return Unsaved signals, one per account, in account order.
     */
    public static List<RIQ_Health_Signal__c> buildSignalsForAccounts(
        List<Account> accounts,
        String signalType,
        Integer severity,
        Date occurredOn
    ) {
        List<RIQ_Health_Signal__c> signals = new List<RIQ_Health_Signal__c>();

        for (Account account : accounts) {
            signals.add(buildSignal(account.Id, signalType, severity, occurredOn));
        }

        return signals;
    }

    /**
     * @return A rule set mirroring the deployed metadata, but owned entirely by
     * the test so engine assertions never depend on org configuration.
     */
    public static Map<String, RIQ_ScoringRule> testRules() {
        return new Map<String, RIQ_ScoringRule>{
            SUPPORT_ESCALATION => new RIQ_ScoringRule(SUPPORT_ESCALATION, 25, 90),
            LOW_PRODUCT_USAGE => new RIQ_ScoringRule(LOW_PRODUCT_USAGE, 15, 60),
            MISSED_QBR => new RIQ_ScoringRule(MISSED_QBR, 10, 120),
            POSITIVE_EXPANSION => new RIQ_ScoringRule(POSITIVE_EXPANSION, -15, 60)
        };
    }

    /**
     * @return The four status bands, in a deliberately unhelpful order so tests
     * prove the engine sorts them itself.
     */
    public static List<RIQ_HealthThreshold> testThresholds() {
        return new List<RIQ_HealthThreshold>{
            new RIQ_HealthThreshold('At Risk', 40),
            new RIQ_HealthThreshold('Healthy', 80),
            new RIQ_HealthThreshold('Critical', 0),
            new RIQ_HealthThreshold('Watch', 60)
        };
    }

    /** Makes repeated test-user creation unique inside one transaction. */
    private static Integer userSequence = 0;

    /**
     * @description Creates a user and assigns the named permission sets, for
     * tests that must run as a CSM or a read-only viewer.
     * @param alias User alias, max 8 characters.
     * @param permissionSetNames API names of permission sets to assign.
     * @return The inserted user.
     */
    public static User createUserWithPermissionSets(String alias, List<String> permissionSetNames) {
        userSequence++;
        String uniqueSuffix = String.valueOf(DateTime.now().getTime()) + '-' + userSequence;
        User user = new User(
            Alias = alias,
            Email = 'riq.user.' + uniqueSuffix + '@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'RenewalIQ Test User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = minimumAccessProfileId(),
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'riq.user.' + uniqueSuffix + '@example.com.invalid'
        );

        insert user;

        // One query and one insert for the whole list: a query and a DML inside
        // a loop is exactly what the PMD rule forbids, and a persona test that
        // grows to three permission sets should not grow to six statements.
        Map<String, Id> permissionSetIdsByName = new Map<String, Id>();

        for (PermissionSet permissionSet : [SELECT Id, Name FROM PermissionSet WHERE Name IN :permissionSetNames]) {
            permissionSetIdsByName.put(permissionSet.Name, permissionSet.Id);
        }

        List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();

        for (String permissionSetName : permissionSetNames) {
            Id permissionSetId = permissionSetIdsByName.get(permissionSetName);
            Assert.isNotNull(permissionSetId, 'Missing permission set in this org: ' + permissionSetName);
            assignments.add(new PermissionSetAssignment(AssigneeId = user.Id, PermissionSetId = permissionSetId));
        }

        insert assignments;
        return user;
    }

    /**
     * @description A syntactically valid Account id that cannot exist. Built at
     * runtime from the real key prefix so tests never depend on an id literal,
     * which is the one thing that genuinely breaks between orgs.
     * @return An 18 character id that resolves to no record.
     */
    public static Id nonExistentAccountId() {
        // A 15 character id: Salesforce validates the checksum of an 18 character
        // id, so a synthesised one has to stay in the short form.
        return Id.valueOf(
            Account.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).getKeyPrefix() + '0'.repeat(12)
        );
    }

    /**
     * @return A profile available in every org edition for permission tests.
     */
    public static Id minimumAccessProfileId() {
        return [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1].Id;
    }

    /**
     * @param profileId Profile to assign.
     * @return An inserted user with no RenewalIQ permission sets.
     */
    public static User createRestrictedUser(Id profileId) {
        String uniqueSuffix = String.valueOf(DateTime.now().getTime());
        User restricted = new User(
            Alias = 'riqusr',
            Email = 'riq.test.' + uniqueSuffix + '@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'RenewalIQ Restricted',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profileId,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'riq.test.' + uniqueSuffix + '@example.com.invalid'
        );

        insert restricted;
        return restricted;
    }
}
