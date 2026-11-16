/**
 * @description Reads the Account fields the scoring engine needs. The engine
 * reads contract data to convert a score into churn probability, so the
 * selector is the single place that dependency is declared.
 */
public class RIQ_AccountSelector extends RIQ_Selector {
    private static final List<String> FIELDS = new List<String>{
        'Id',
        'Name',
        'OwnerId',
        'RIQ_ARR__c',
        'RIQ_Contract_End_Date__c',
        'RIQ_Health_Score__c',
        'RIQ_Health_Status__c'
    };

    /**
     * @param requestedAccessMode USER_MODE by default.
     */
    public RIQ_AccountSelector(AccessLevel requestedAccessMode) {
        super(requestedAccessMode);
    }

    public RIQ_AccountSelector() {
        super();
    }

    /**
     * @description Loads accounts for a bulk recalculation in one query.
     * @param accountIds Accounts to load.
     * @return Accounts in the supplied id set; empty when no ids are supplied.
     */
    public List<Account> getByIds(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) {
            return new List<Account>();
        }

        String soql = 'SELECT ' + String.join(FIELDS, ', ') + ' FROM Account WHERE Id IN :accountIds';
        Map<String, Object> binds = new Map<String, Object>{ 'accountIds' => accountIds };
        return (List<Account>) query(soql, binds);
    }

    /**
     * @description Loads the fields the health card renders. Kept separate from
     * getByIds so the scoring engine still reads only what scoring needs.
     * @param accountIds Accounts to load.
     * @return Accounts in the supplied id set; empty when none are visible.
     */
    public List<Account> getForHealthCards(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) {
            return new List<Account>();
        }

        String soql =
            'SELECT Id, Name, OwnerId, Owner.Name, RIQ_ARR__c, RIQ_Contract_End_Date__c,' +
            ' RIQ_Health_Score__c, RIQ_Health_Status__c, RIQ_Churn_Probability__c, RIQ_Last_Scored__c' +
            ' FROM Account' +
            ' WHERE Id IN :accountIds';
        Map<String, Object> binds = new Map<String, Object>{ 'accountIds' => accountIds };
        return (List<Account>) query(soql, binds);
    }
}
