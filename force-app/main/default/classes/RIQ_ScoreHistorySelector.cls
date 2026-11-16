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
}
