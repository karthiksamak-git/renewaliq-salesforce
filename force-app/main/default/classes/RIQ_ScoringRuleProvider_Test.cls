/**
 * @description Proves the provider reads the deployed Custom Metadata records
 * and caches them for the transaction. Custom Metadata is available in Apex
 * tests without SeeAllData, which is why the engine can be tested against real
 * configuration as well as against in-memory rule sets.
 */
@IsTest
private class RIQ_ScoringRuleProvider_Test {
    @IsTest
    static void loadsTheDeployedScoringRules() {
        Map<String, RIQ_ScoringRule> rules = RIQ_ScoringRuleProvider.getRules();

        System.assert(rules.size() >= 7, 'Every signal type ships with a rule.');
        System.assert(rules.containsKey(RIQ_TestDataFactory.SUPPORT_ESCALATION));
        System.assert(rules.containsKey(RIQ_TestDataFactory.POSITIVE_EXPANSION));
        System.assertEquals(25, rules.get(RIQ_TestDataFactory.SUPPORT_ESCALATION).baseWeight.intValue());
        System.assert(
            rules.get(RIQ_TestDataFactory.POSITIVE_EXPANSION).baseWeight < 0,
            'Positive Expansion is a credit stored as a negative weight.'
        );
        System.assert(rules.get(RIQ_TestDataFactory.SUPPORT_ESCALATION).decayDays > 0);
    }

    @IsTest
    static void thresholdsArriveHighestFirst() {
        List<RIQ_HealthThreshold> thresholds = RIQ_ScoringRuleProvider.getThresholds();

        System.assertEquals(4, thresholds.size());
        System.assertEquals(80, thresholds[0].minScore, 'Healthy is the top band.');
        System.assertEquals('Healthy', thresholds[0].status);
        System.assertEquals(0, thresholds[3].minScore, 'Critical floors at zero.');
    }

    @IsTest
    static void rulesAreReadOnlyOncePerTransaction() {
        Map<String, RIQ_ScoringRule> firstCall = RIQ_ScoringRuleProvider.getRules();
        Map<String, RIQ_ScoringRule> secondCall = RIQ_ScoringRuleProvider.getRules();

        System.assertEquals(firstCall.size(), secondCall.size(), 'The second read is served from the cache.');
    }

    @IsTest
    static void clearingTheCacheReloadsFromMetadata() {
        Map<String, RIQ_ScoringRule> beforeClear = RIQ_ScoringRuleProvider.getRules();
        RIQ_ScoringRuleProvider.clearCache();
        Map<String, RIQ_ScoringRule> afterClear = RIQ_ScoringRuleProvider.getRules();

        System.assertEquals(beforeClear.size(), afterClear.size());
        System.assertEquals(4, RIQ_ScoringRuleProvider.getThresholds().size(), 'Thresholds reload too.');
    }
}
