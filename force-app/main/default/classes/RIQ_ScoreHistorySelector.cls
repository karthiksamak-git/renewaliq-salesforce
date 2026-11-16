/**
 * @description Reads score history for the trend chart. History is the only
 * place a trend can come from, because the Account stores one number and the
 * dashboard needs the shape over time.
 */
public with sharing class RIQ_ScoreHistorySelector extends RIQ_Selector {
    private static final List<String> FIELDS = new List<String>{
        'Id',
        'Account__c',
        'Score__c',
        'Status__c',
        'Calculated_On__c',
        'Drivers__c'
    };

    /**
     * @param requestedAccessMode USER_MODE by default.
     */
    public RIQ_ScoreHistorySelector(AccessLevel requestedAccessMode) {
        super(requestedAccessMode);
    }

    public RIQ_ScoreHistorySelector() {
        super();
    }

    /**
     * @description Newest history rows for one account.
     * @param accountId Account to read.
     * @param rowLimit Maximum rows.
     * @return History ordered newest first.
     */
    public List<RIQ_Score_History__c> getLatestForAccount(Id accountId, Integer rowLimit) {
        if (accountId == null) {
            return new List<RIQ_Score_History__c>();
        }

        String soql =
            'SELECT ' +
            String.join(FIELDS, ', ') +
            ' FROM RIQ_Score_History__c' +
            ' WHERE Account__c = :accountId' +
            ' ORDER BY Calculated_On__c DESC, Id DESC' +
            ' LIMIT :rowLimit';
        Map<String, Object> binds = new Map<String, Object>{ 'accountId' => accountId, 'rowLimit' => rowLimit };
        return (List<RIQ_Score_History__c>) query(soql, binds);
    }

    /**
     * @description Recent history for several accounts in one query, newest
     * first. Callers take the first row per account; the row limit is what keeps
     * a multi-account job from pulling a year of history it does not need.
     * @param accountIds Accounts to read.
     * @param rowLimit Maximum rows across all accounts.
     * @return History ordered newest first; empty when no ids are supplied.
     */
    public List<RIQ_Score_History__c> getRecentForAccounts(Set<Id> accountIds, Integer rowLimit) {
        if (accountIds == null || accountIds.isEmpty()) {
            return new List<RIQ_Score_History__c>();
        }

        String soql =
            'SELECT ' +
            String.join(FIELDS, ', ') +
            ' FROM RIQ_Score_History__c' +
            ' WHERE Account__c IN :accountIds' +
            ' ORDER BY Calculated_On__c DESC, Id DESC' +
            ' LIMIT :rowLimit';
        Map<String, Object> binds = new Map<String, Object>{ 'accountIds' => accountIds, 'rowLimit' => rowLimit };
        return (List<RIQ_Score_History__c>) query(soql, binds);
    }
}
