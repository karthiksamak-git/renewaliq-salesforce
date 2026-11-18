/**
 * @description Base class for every RenewalIQ selector. All SOQL in the app goes
 * through a selector, which gives three guarantees in one place:
 *
 * 1. Queries run WITH USER_MODE by default, so object and field level security
 *    and sharing rules are enforced by the platform instead of by convention.
 * 2. Callers cannot build an unbounded query: the id set is always a bind.
 * 3. A caller that genuinely needs system context (the scoring engine writing
 *    fields no user may edit) has to ask for it explicitly and visibly.
 *
 * Selectors do not declare a sharing keyword; they inherit the caller's mode.
 * USER_MODE still enforces sharing for the records themselves.
 */
// NOPMD ApexSharingViolations: this class deliberately declares no sharing
// keyword and inherits the caller's mode. USER_MODE still enforces record
// sharing on every query; declaring `with sharing` here would silently change
// the behaviour of the system-context callers that pass SYSTEM_MODE.
public virtual class RIQ_Selector { // NOPMD inherits the caller's sharing mode on purpose
    @TestVisible
    private AccessLevel accessMode;

    public RIQ_Selector() {
        this(AccessLevel.USER_MODE);
    }

    /**
     * @param accessLevel USER_MODE (default) or SYSTEM_MODE. SYSTEM_MODE is for
     * system-maintained data only - never for a user-facing query.
     */
    public RIQ_Selector(AccessLevel requestedAccessMode) {
        this.accessMode = requestedAccessMode == null ? AccessLevel.USER_MODE : requestedAccessMode;
    }

    /**
     * @description Runs a dynamic SOQL query with bind variables at the
     * configured access level. Binds must be supplied as a map so no value is
     * ever concatenated into the query string.
     * @param queryString SOQL using :bindName placeholders.
     * @param binds Map of bind name to value; may be null for no binds.
     * @return Query rows as generic SObjects.
     */
    protected List<SObject> query(String queryString, Map<String, Object> binds) {
        Map<String, Object> safeBinds = binds == null ? new Map<String, Object>() : binds;
        return Database.queryWithBinds(queryString, safeBinds, accessMode);
    }

    /**
     * @description Convenience overload for queries with no bind variables.
     * @param queryString SOQL with no placeholders.
     * @return Query rows as generic SObjects.
     */
    protected List<SObject> query(String queryString) {
        return query(queryString, null);
    }

    /**
     * @description Removes fields the running user cannot write before DML, and
     * throws when the user cannot create the record's object at all. Used by
     * user-facing writes; system writes use SYSTEM_MODE instead.
     * @param records Records about to be written.
     * @param accessType AccessType.CREATABLE, UPDATABLE or READABLE.
     * @return The same records, stripped of inaccessible fields.
     */
    protected List<SObject> stripInaccessible(List<SObject> records, AccessType requestedAccessType) {
        if (records == null || records.isEmpty()) {
            return records;
        }

        return Security.stripInaccessible(requestedAccessType, records, true).getRecords();
    }
}
