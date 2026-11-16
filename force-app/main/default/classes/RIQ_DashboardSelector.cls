/**
 * @description Reads for the Command Center dashboard. All SOQL for the
 * dashboard lives here so the controller contains no query text, and every
 * statement runs in USER_MODE - the dashboard must never show an account the
 * viewer cannot see.
 *
 * Aggregates are done in SOQL, not in Apex: a health dashboard should cost a
 * handful of grouped queries, not a loop over every customer.
 */
public with sharing class RIQ_DashboardSelector extends RIQ_Selector {
    /**
     * @param requestedAccessMode USER_MODE by default.
     */
    public RIQ_DashboardSelector(AccessLevel requestedAccessMode) {
        super(requestedAccessMode);
    }

    public RIQ_DashboardSelector() {
        super();
    }

    /**
     * @description Count, ARR and average score grouped by health status. One
     * query feeds the KPI tiles and the status donut, so the two can never
     * disagree in the same render.
     * @param ownerId Optional owner filter.
     * @return One aggregate row per status present in scope.
     */
    public List<AggregateResult> getStatusTotals(Id ownerId) {
        String soql =
            'SELECT RIQ_Health_Status__c status, COUNT(Id) total, SUM(RIQ_ARR__c) arr, AVG(RIQ_Health_Score__c) avgScore' +
            ' FROM Account' +
            ' WHERE RIQ_ARR__c != NULL';
        Map<String, Object> binds = new Map<String, Object>();

        if (ownerId != null) {
            soql += ' AND OwnerId = :ownerId';
            binds.put('ownerId', ownerId);
        }

        soql += ' GROUP BY RIQ_Health_Status__c';

        return toAggregates(query(soql, binds));
    }

    /**
     * @description Accounts whose contract ends inside the renewal window.
     * @param ownerId Optional owner filter.
     * @param windowEnd Last day of the window (inclusive).
     * @return Count of renewals due.
     */
    public Integer countRenewalsDue(Id ownerId, Date windowEnd) {
        String soql =
            'SELECT COUNT(Id) total' +
            ' FROM Account' +
            ' WHERE RIQ_ARR__c != NULL' +
            ' AND RIQ_Contract_End_Date__c >= TODAY' +
            ' AND RIQ_Contract_End_Date__c <= :windowEnd';
        Map<String, Object> binds = new Map<String, Object>{ 'windowEnd' => windowEnd };

        if (ownerId != null) {
            soql += ' AND OwnerId = :ownerId';
            binds.put('ownerId', ownerId);
        }

        List<AggregateResult> results = toAggregates(query(soql, binds));
        return results.isEmpty() ? 0 : (Integer) results[0].get('total');
    }

    /**
     * @description The drill-down list. Every filter is optional, the sort field
     * and direction are whitelisted by the caller, and the row count is always
     * bounded.
     * @param statuses Statuses to include; never empty.
     * @param ownerId Optional owner filter.
     * @param windowEnd Optional last day of the renewal window.
     * @param orderByField Whitelisted API field name to sort by.
     * @param direction ASC or DESC.
     * @param rowLimit Maximum rows to return.
     * @return Accounts in scope.
     */
    public List<Account> getRiskAccounts(
        Set<String> statuses,
        Id ownerId,
        Date windowEnd,
        String orderByField,
        String direction,
        Integer rowLimit
    ) {
        String soql =
            'SELECT Id, Name, OwnerId, Owner.Name, RIQ_Health_Score__c, RIQ_Health_Status__c,' +
            ' RIQ_Churn_Probability__c, RIQ_ARR__c, RIQ_Contract_End_Date__c' +
            ' FROM Account' +
            ' WHERE RIQ_Health_Status__c IN :statuses';
        Map<String, Object> binds = new Map<String, Object>{ 'statuses' => statuses };

        if (ownerId != null) {
            soql += ' AND OwnerId = :ownerId';
            binds.put('ownerId', ownerId);
        }

        if (windowEnd != null) {
            soql += ' AND RIQ_Contract_End_Date__c >= TODAY AND RIQ_Contract_End_Date__c <= :windowEnd';
            binds.put('windowEnd', windowEnd);
        }

        soql += ' ORDER BY ' + orderByField + ' ' + direction + ', Name';
        soql += ' LIMIT :rowLimit';
        binds.put('rowLimit', rowLimit);

        return (List<Account>) query(soql, binds);
    }

    /**
     * @description Distinct owners of in-scope accounts, for the owner filter.
     * Grouped in SOQL rather than by scanning rows in Apex.
     * @return One row per owner, ordered by name.
     */
    public List<AggregateResult> getOwners() {
        String soql =
            'SELECT OwnerId ownerId, Owner.Name ownerName, COUNT(Id) total' +
            ' FROM Account' +
            ' WHERE RIQ_ARR__c != NULL' +
            ' GROUP BY OwnerId, Owner.Name' +
            ' ORDER BY Owner.Name' +
            ' LIMIT 200';

        return toAggregates(query(soql));
    }

    /**
     * @param rows Generic rows returned by the selector base class.
     * @return The same rows typed as AggregateResult.
     */
    private static List<AggregateResult> toAggregates(List<SObject> rows) {
        List<AggregateResult> aggregates = new List<AggregateResult>();

        for (SObject row : rows) {
            aggregates.add((AggregateResult) row);
        }

        return aggregates;
    }
}
