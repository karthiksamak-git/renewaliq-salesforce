/**
 * @description Reads the health signals that feed the scoring engine. Only the
 * fields the engine actually reads are selected, which keeps the query cheap and
 * makes the engine's data dependencies obvious.
 */
public class RIQ_HealthSignalSelector extends RIQ_Selector {
    private static final List<String> FIELDS = new List<String>{
        'Id',
        'Account__c',
        'Signal_Type__c',
        'Severity__c',
        'Occurred_On__c',
        'Weight_Override__c'
    };

    /**
     * @param requestedAccessMode USER_MODE by default.
     */
    public RIQ_HealthSignalSelector(AccessLevel requestedAccessMode) {
        super(requestedAccessMode);
    }

    public RIQ_HealthSignalSelector() {
        super();
    }

    /**
     * @description Returns every signal for the supplied accounts in one query.
     * The caller groups them in memory, so a 200 account recalculation is still
     * a single SOQL statement instead of one query per account.
     * @param accountIds Accounts to load signals for.
     * @return Signals ordered newest first; empty when no ids are supplied.
     */
    public List<RIQ_Health_Signal__c> getByAccountIds(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) {
            return new List<RIQ_Health_Signal__c>();
        }

        String soql =
            'SELECT ' +
            String.join(FIELDS, ', ') +
            ' FROM RIQ_Health_Signal__c' +
            ' WHERE Account__c IN :accountIds' +
            ' ORDER BY Occurred_On__c DESC, Id';

        Map<String, Object> binds = new Map<String, Object>{ 'accountIds' => accountIds };
        return (List<RIQ_Health_Signal__c>) query(soql, binds);
    }
}
