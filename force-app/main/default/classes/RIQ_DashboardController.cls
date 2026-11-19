/**
 * @description Backs the Command Center. Thin by design: it resolves filters,
 * turns selector rows into @AuraEnabled DTOs, and converts every failure into a
 * message a Customer Success manager can act on instead of a raw
 * QueryException.
 *
 * Cacheable is set on the three read methods only. They are pure reads, so the
 * client may cache them; anything that mutates state lives on
 * RIQ_AccountHealthController and is deliberately non-cacheable.
 */
public with sharing class RIQ_DashboardController {
    /** Window used when the caller does not supply one. */
    public static final Integer DEFAULT_WINDOW_DAYS = 90;
    /** Hard ceiling on the renewal window so no caller can ask for "all time". */
    private static final Integer MAX_WINDOW_DAYS = 730;
    /** Rows returned when the caller does not ask for a size. */
    private static final Integer DEFAULT_MAX_ROWS = 50;
    /** Hard ceiling on returned rows - the list is never unbounded. */
    private static final Integer MAX_MAX_ROWS = 200;
    /** Sort keys the client may use, mapped to real field paths. */
    private static final Map<String, String> SORT_FIELDS = new Map<String, String>{
        'score' => 'RIQ_Health_Score__c',
        'arr' => 'RIQ_ARR__c',
        'churn' => 'RIQ_Churn_Probability__c',
        'churnProbability' => 'RIQ_Churn_Probability__c',
        'renewal' => 'RIQ_Contract_End_Date__c',
        'contractEndDate' => 'RIQ_Contract_End_Date__c',
        'name' => 'Name',
        'recordUrl' => 'Name',
        'status' => 'RIQ_Health_Status__c',
        'owner' => 'Owner.Name',
        'ownerName' => 'Owner.Name'
    };
    /** Statuses that count as at-risk revenue. */
    private static final Set<String> AT_RISK_STATUSES = new Set<String>{ 'At Risk', 'Critical' };
    /** Donut order, worst first. */
    private static final Map<String, Integer> STATUS_RANK = new Map<String, Integer>{
        'Critical' => 0,
        'At Risk' => 1,
        'Watch' => 2,
        'Healthy' => 3
    };

    /** KPI tiles for the dashboard header. */
    public class Kpi {
        /** Sum of ARR across in-scope accounts. */
        @AuraEnabled
        public Decimal totalArr = 0;
        /** Sum of ARR for At Risk + Critical accounts. */
        @AuraEnabled
        public Decimal arrAtRisk = 0;
        /** Number of accounts currently Critical. */
        @AuraEnabled
        public Integer criticalCount = 0;
        /** Mean health score, one decimal; null when nothing is scored. */
        @AuraEnabled
        public Decimal averageScore;
        /** Contracts ending inside the window. */
        @AuraEnabled
        public Integer renewalsDue = 0;
        /** Accounts in scope. */
        @AuraEnabled
        public Integer accountCount = 0;
        /** The window actually applied. */
        @AuraEnabled
        public Integer renewalWindowDays;
    }

    /** One slice of the status donut. */
    public class StatusSlice {
        /** Status label. */
        @AuraEnabled
        public String label;
        /** Accounts in that status. */
        @AuraEnabled
        public Integer count;
        /** ARR in that status. */
        @AuraEnabled
        public Decimal arr;
        /** Share of accounts, 0..100 with one decimal. */
        @AuraEnabled
        public Decimal percentage;
    }

    /** One row of the at-risk table. */
    public class RiskRow {
        /** Account id. */
        @AuraEnabled
        public Id accountId;
        /** Account name. */
        @AuraEnabled
        public String name;
        /** Owner name. */
        @AuraEnabled
        public String ownerName;
        /** Health status. */
        @AuraEnabled
        public String status;
        /** Health score. */
        @AuraEnabled
        public Integer score;
        /** Churn probability. */
        @AuraEnabled
        public Integer churnProbability;
        /** ARR. */
        @AuraEnabled
        public Decimal arr;
        /** Contract end date. */
        @AuraEnabled
        public Date contractEndDate;
        /** Days until the contract ends; negative when overdue. */
        @AuraEnabled
        public Integer daysToRenewal;
        /** In-app link to the record. */
        @AuraEnabled
        public String recordUrl;
        /** When the score was last written; null means never scored. */
        @AuraEnabled
        public DateTime lastScored;
    }

    /** One option of the owner filter. */
    public class OwnerOption {
        /** User id. */
        @AuraEnabled
        public Id ownerId;
        /** Display name. */
        @AuraEnabled
        public String ownerName;
    }

    /**
     * @param ownerId Optional owner filter.
     * @param renewalWindowDays Days ahead to count renewals for.
     * @return KPI tiles.
     */
    @AuraEnabled(cacheable=true)
    public static Kpi getKpis(Id ownerId, Integer renewalWindowDays) {
        Integer window = normaliseWindow(renewalWindowDays);

        try {
            RIQ_DashboardSelector selector = new RIQ_DashboardSelector();
            Kpi kpi = new Kpi();
            kpi.renewalWindowDays = window;

            Decimal weightedScore = 0;
            Integer scoredAccounts = 0;

            for (AggregateResult row : selector.getStatusTotals(ownerId)) {
                String status = (String) row.get('status');
                Integer count = toInteger(row.get('total'));
                Decimal arr = toDecimal(row.get('arr'));
                Decimal averageScore = toDecimal(row.get('avgScore'));

                kpi.accountCount += count;
                kpi.totalArr += arr;

                if (AT_RISK_STATUSES.contains(status)) {
                    kpi.arrAtRisk += arr;

                    if (status == 'Critical') {
                        kpi.criticalCount += count;
                    }
                }

                if (averageScore != null && count > 0) {
                    weightedScore += averageScore * count;
                    scoredAccounts += count;
                }
            }

            if (scoredAccounts > 0) {
                kpi.averageScore = (weightedScore / scoredAccounts).setScale(1, RoundingMode.HALF_UP);
            }

            kpi.renewalsDue = selector.countRenewalsDue(ownerId, Date.today().addDays(window));
            return kpi;
        } catch (AuraHandledException friendly) {
            throw friendly;
        } catch (Exception failure) {
            throw handleFailure(failure, 'read the dashboard');
        }
    }

    /**
     * @param ownerId Optional owner filter.
     * @return Donut slices, ordered Critical, At Risk, Watch, Healthy.
     */
    @AuraEnabled(cacheable=true)
    public static List<StatusSlice> getStatusDistribution(Id ownerId) {
        try {
            List<StatusSlice> slices = new List<StatusSlice>();
            Integer total = 0;

            for (AggregateResult row : new RIQ_DashboardSelector().getStatusTotals(ownerId)) {
                StatusSlice slice = new StatusSlice();
                slice.label = (String) row.get('status');
                slice.count = toInteger(row.get('total'));
                slice.arr = toDecimal(row.get('arr'));
                total += slice.count;
                slices.add(slice);
            }

            for (StatusSlice slice : slices) {
                slice.percentage = total == 0
                    ? 0
                    : ((Decimal) slice.count * 100 / total).setScale(1, RoundingMode.HALF_UP);
            }

            sortByStatus(slices);
            return slices;
        } catch (Exception failure) {
            throw handleFailure(failure, 'read the status distribution');
        }
    }

    /**
     * @param statusFilter Null or 'All' for At Risk + Critical, otherwise a
     *        single valid status.
     * @param ownerId Optional owner filter.
     * @param renewalWindowDays Optional renewal window; null means any date.
     * @param sortBy Whitelisted sort key.
     * @param sortDirection ASC or DESC.
     * @param maxRows Requested size, clamped.
     * @return The at-risk table rows.
     */
    @AuraEnabled(cacheable=true)
    public static List<RiskRow> getAtRiskAccounts(
        String statusFilter,
        Id ownerId,
        Integer renewalWindowDays,
        String sortBy,
        String sortDirection,
        Integer maxRows
    ) {
        Set<String> statuses = resolveStatuses(statusFilter);
        String orderByField = SORT_FIELDS.containsKey(sortBy) ? SORT_FIELDS.get(sortBy) : 'RIQ_Health_Score__c';
        String direction = 'ASC'.equalsIgnoreCase(sortDirection) ? 'ASC' : 'DESC';
        Integer rowLimit = clampRows(maxRows);
        Date windowEnd = renewalWindowDays == null ||
            renewalWindowDays <= 0
            ? null
            : Date.today().addDays(normaliseWindow(renewalWindowDays));

        try {
            List<RiskRow> rows = new List<RiskRow>();

            for (
                Account account : new RIQ_DashboardSelector()
                    .getRiskAccounts(statuses, ownerId, windowEnd, orderByField, direction, rowLimit)
            ) {
                RiskRow row = new RiskRow();
                row.accountId = account.Id;
                row.name = account.Name;
                row.ownerName = account.Owner.Name;
                row.status = account.RIQ_Health_Status__c;
                row.score = account.RIQ_Health_Score__c == null ? null : account.RIQ_Health_Score__c.intValue();
                row.churnProbability = account.RIQ_Churn_Probability__c == null
                    ? null
                    : account.RIQ_Churn_Probability__c.intValue();
                row.arr = account.RIQ_ARR__c;
                row.contractEndDate = account.RIQ_Contract_End_Date__c;
                row.daysToRenewal = account.RIQ_Contract_End_Date__c == null
                    ? null
                    : Date.today().daysBetween(account.RIQ_Contract_End_Date__c);
                row.recordUrl = '/' + account.Id;
                row.lastScored = account.RIQ_Last_Scored__c;
                rows.add(row);
            }

            return rows;
        } catch (Exception failure) {
            throw handleFailure(failure, 'read the at-risk accounts');
        }
    }

    /**
     * @description The number of accounts the current filters match, so the UI
     * can say "Showing 40 of 57" instead of implying the row limit is the total.
     * @param statusFilter Null or 'All' for At Risk + Critical.
     * @param ownerId Optional owner filter.
     * @param renewalWindowDays Optional renewal window; null means any date.
     * @return Matching account count.
     */
    @AuraEnabled(cacheable=true)
    public static Integer getRowCount(String statusFilter, Id ownerId, Integer renewalWindowDays) {
        Set<String> statuses = resolveStatuses(statusFilter);
        Date windowEnd = renewalWindowDays == null ||
            renewalWindowDays <= 0
            ? null
            : Date.today().addDays(normaliseWindow(renewalWindowDays));

        try {
            return new RIQ_DashboardSelector().countRiskAccounts(statuses, ownerId, windowEnd);
        } catch (Exception failure) {
            throw handleFailure(failure, 'count the accounts needing attention');
        }
    }

    /**
     * @return Distinct owners of in-scope accounts, for the owner filter.
     */
    @AuraEnabled(cacheable=true)
    public static List<OwnerOption> getOwners() {
        try {
            List<OwnerOption> owners = new List<OwnerOption>();

            for (AggregateResult row : new RIQ_DashboardSelector().getOwners()) {
                OwnerOption option = new OwnerOption();
                option.ownerId = (Id) row.get('ownerId');
                option.ownerName = (String) row.get('ownerName');
                owners.add(option);
            }

            return owners;
        } catch (Exception failure) {
            throw handleFailure(failure, 'read the account owners');
        }
    }

    /**
     * @description Orders slices worst-first. Apex has no Comparator, and the
     * list is at most five entries, so an insertion sort is the simplest thing
     * that works.
     * @param slices Slices to order in place.
     */
    private static void sortByStatus(List<StatusSlice> slices) {
        for (Integer i = 1; i < slices.size(); i++) {
            StatusSlice current = slices[i];
            Integer j = i - 1;

            while (j >= 0 && rankOf(slices[j]) > rankOf(current)) {
                slices[j + 1] = slices[j];
                j--;
            }

            slices[j + 1] = current;
        }
    }

    /**
     * @param slice Slice to rank.
     * @return Position in the donut; unknown statuses sort last.
     */
    private static Integer rankOf(StatusSlice slice) {
        Integer rank = STATUS_RANK.get(slice.label);
        return rank == null ? 99 : rank;
    }

    /**
     * @param statusFilter Raw filter from the UI.
     * @return A non-empty set of valid statuses.
     */
    private static Set<String> resolveStatuses(String statusFilter) {
        if (String.isBlank(statusFilter) || 'All'.equalsIgnoreCase(statusFilter)) {
            return AT_RISK_STATUSES;
        }

        if (!statusPicklistValues().contains(statusFilter)) {
            throw userError('"' + statusFilter + '" is not a valid health status.');
        }

        return new Set<String>{ statusFilter };
    }

    /**
     * @return The deployed picklist values for Account.RIQ_Health_Status__c.
     */
    private static Set<String> statusPicklistValues() {
        Set<String> values = new Set<String>();

        for (Schema.PicklistEntry entry : Account.RIQ_Health_Status__c.getDescribe().getPicklistValues()) {
            values.add(entry.getValue());
        }

        return values;
    }

    /**
     * @param requested Requested window.
     * @return A sane window in days.
     */
    private static Integer normaliseWindow(Integer requested) {
        if (requested == null || requested <= 0) {
            return DEFAULT_WINDOW_DAYS;
        }

        return requested > MAX_WINDOW_DAYS ? MAX_WINDOW_DAYS : requested;
    }

    /**
     * @param requested Requested row count.
     * @return A sane, bounded row count.
     */
    private static Integer clampRows(Integer requested) {
        if (requested == null || requested <= 0) {
            return DEFAULT_MAX_ROWS;
        }

        return requested > MAX_MAX_ROWS ? MAX_MAX_ROWS : requested;
    }

    /**
     * @param value Aggregate value.
     * @return Integer or 0.
     */
    private static Integer toInteger(Object value) {
        return value == null ? 0 : (Integer) Integer.valueOf(String.valueOf(value));
    }

    /**
     * @param value Aggregate value.
     * @return Decimal or 0.
     */
    private static Decimal toDecimal(Object value) {
        return value == null ? 0 : Decimal.valueOf(String.valueOf(value));
    }

    /**
     * @param failure The internal error.
     * @param action What the caller was trying to do.
     * @return A friendly exception carrying a support-safe message.
     */
    private static AuraHandledException handleFailure(Exception failure, String action) {
        RIQ_Logger.error('RIQ_DashboardController', 'Could not ' + action + '.', failure);
        return userError(
            'RenewalIQ could not ' +
                action +
                '. If this keeps happening, check that your user has the RIQ_CSM or RIQ_Read_Only permission set.'
        );
    }

    /**
     * @param message Message shown to the user.
     * @return An AuraHandledException that keeps its message on the client.
     */
    private static AuraHandledException userError(String message) {
        AuraHandledException friendly = new AuraHandledException(message);
        friendly.setMessage(message);
        return friendly;
    }
}
