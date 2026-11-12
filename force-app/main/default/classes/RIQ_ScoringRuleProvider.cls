/**
 * @description Loads scoring configuration from Custom Metadata and caches it
 * for the rest of the transaction. Custom Metadata is cached because a single
 * recalculation would otherwise issue the same query once per account - the
 * classic "SOQL in a loop" that bulk testing is supposed to catch.
 *
 * Thresholds are returned ordered by Min_Score descending so the first band a
 * score satisfies is the right one.
 */
public with sharing class RIQ_ScoringRuleProvider {
    private static Map<String, RIQ_ScoringRule> rulesBySignalType;
    private static List<RIQ_HealthThreshold> thresholds;

    /**
     * @description Active scoring rules keyed by signal type. Signals whose type
     * has no rule are ignored by the engine, which is how a signal type is
     * retired without deleting its history.
     * @return Cached, read-only-in-practice map of rules.
     */
    public static Map<String, RIQ_ScoringRule> getRules() {
        if (rulesBySignalType == null) {
            rulesBySignalType = new Map<String, RIQ_ScoringRule>();

            for (RIQ_Scoring_Rule__mdt rule : [
                SELECT Signal_Type__c, Base_Weight__c, Decay_Days__c
                FROM RIQ_Scoring_Rule__mdt
                WHERE Is_Active__c = TRUE
            ]) {
                rulesBySignalType.put(
                    rule.Signal_Type__c,
                    new RIQ_ScoringRule(rule.Signal_Type__c, rule.Base_Weight__c, toInteger(rule.Decay_Days__c))
                );
            }
        }

        return rulesBySignalType;
    }

    /**
     * @description Status bands ordered from highest Min_Score to lowest.
     * @return Cached list of thresholds.
     */
    public static List<RIQ_HealthThreshold> getThresholds() {
        if (thresholds == null) {
            thresholds = new List<RIQ_HealthThreshold>();

            for (RIQ_Threshold__mdt threshold : [
                SELECT Status__c, Min_Score__c
                FROM RIQ_Threshold__mdt
                ORDER BY Min_Score__c DESC
            ]) {
                thresholds.add(new RIQ_HealthThreshold(threshold.Status__c, toInteger(threshold.Min_Score__c)));
            }
        }

        return thresholds;
    }

    /**
     * @description Drops the cache so the next call re-reads metadata. Only
     * needed by tests and by admin tooling that changes rules mid-transaction.
     */
    @TestVisible
    private static void clearCache() {
        rulesBySignalType = null;
        thresholds = null;
    }

    /**
     * @param value Number field from Custom Metadata.
     * @return Safe integer, zero when blank.
     */
    private static Integer toInteger(Decimal value) {
        return value == null ? 0 : value.intValue();
    }
}
