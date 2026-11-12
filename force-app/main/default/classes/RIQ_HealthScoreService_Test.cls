/**
 * @description Edge cases for the scoring engine. Every test builds its own
 * rules and thresholds through the factory, so these assertions describe the
 * formula rather than whatever happens to be configured in the org.
 */
@IsTest
private class RIQ_HealthScoreService_Test {
    private static final Date TODAY = Date.newInstance(2026, 1, 15);

    /**
     * @param signalType Picklist value.
     * @param severity Severity 1..5.
     * @param occurredOn Date the signal occurred.
     * @return An unsaved signal.
     */
    private static RIQ_Health_Signal__c signal(String signalType, Integer severity, Date occurredOn) {
        return RIQ_TestDataFactory.buildSignal(null, signalType, severity, occurredOn);
    }

    /**
     * @param signals Signals to score.
     * @param daysToRenewal Days until contract end.
     * @return The engine result using the factory rule and band set.
     */
    private static RIQ_HealthScoreService.ScoreResult score(List<RIQ_Health_Signal__c> signals, Integer daysToRenewal) {
        return RIQ_HealthScoreService.calculate(
            signals,
            TODAY,
            daysToRenewal,
            RIQ_TestDataFactory.testRules(),
            RIQ_TestDataFactory.testThresholds()
        );
    }

    @IsTest
    static void accountWithNoSignalsIsPerfectlyHealthy() {
        RIQ_HealthScoreService.ScoreResult result = score(new List<RIQ_Health_Signal__c>(), null);

        System.assertEquals(100, result.score, 'A customer with no signals starts at 100.');
        System.assertEquals('Healthy', result.status, '100 belongs to the top band.');
        System.assertEquals(0, result.churnProbability, 'No signals and no renewal date means no churn risk.');
        System.assertEquals(0, result.drivers.size(), 'Nothing contributed, so there are no drivers.');
    }

    @IsTest
    static void nullSignalsAreTreatedAsNoSignals() {
        RIQ_HealthScoreService.ScoreResult result = score(null, 200);

        System.assertEquals(100, result.score);
        System.assertEquals(0, result.drivers.size());
    }

    @IsTest
    static void singleCriticalSignalRemovesBaseWeightTimesSeverity() {
        // Support Escalation: weight 25, severity 3, no decay -> 75 points gone.
        RIQ_HealthScoreService.ScoreResult result = score(
            new List<RIQ_Health_Signal__c>{ signal('Support Escalation', 3, TODAY) },
            null
        );

        System.assertEquals(25, result.score);
        System.assertEquals('Critical', result.status);
        System.assertEquals(1, result.drivers.size());
        System.assertEquals(75, result.drivers[0].points.intValue(), 'The driver reports the points it removed.');
    }

    @IsTest
    static void churnProbabilityRoundsHalfUp() {
        // Score 25 -> 75 risk points * 0.9 = 67.5 -> 68.
        RIQ_HealthScoreService.ScoreResult result = score(
            new List<RIQ_Health_Signal__c>{ signal('Support Escalation', 3, TODAY) },
            null
        );

        System.assertEquals(68, result.churnProbability);
    }

    @IsTest
    static void fullyDecayedSignalIsIgnored() {
        // Occurred 120 days ago with a 90 day window: contribution is zero.
        RIQ_HealthScoreService.ScoreResult result = score(
            new List<RIQ_Health_Signal__c>{ signal('Support Escalation', 5, TODAY.addDays(-120)) },
            null
        );

        System.assertEquals(100, result.score, 'An old signal must not keep dragging the score down.');
        System.assertEquals(0, result.drivers.size(), 'A fully decayed signal does not explain anything.');
    }

    @IsTest
    static void decayIsLinearAcrossTheWindow() {
        // 45 of 90 days elapsed -> half weight: 25 * 2 * 0.5 = 25 points.
        RIQ_HealthScoreService.ScoreResult result = score(
            new List<RIQ_Health_Signal__c>{ signal('Support Escalation', 2, TODAY.addDays(-45)) },
            null
        );

        System.assertEquals(75, result.score);
        System.assertEquals('Watch', result.status);
        System.assertEquals(25, result.drivers[0].points.intValue());
    }

    @IsTest
    static void signalOnTheDecayBoundaryIsWorthNothing() {
        RIQ_HealthScoreService.ScoreResult result = score(
            new List<RIQ_Health_Signal__c>{ signal('Support Escalation', 5, TODAY.addDays(-90)) },
            null
        );

        System.assertEquals(100, result.score);
    }

    @IsTest
    static void futureDatedSignalCountsAtFullWeight() {
        RIQ_HealthScoreService.ScoreResult result = score(
            new List<RIQ_Health_Signal__c>{ signal('Support Escalation', 1, TODAY.addDays(5)) },
            null
        );

        System.assertEquals(75, result.score, 'A future date must not amplify the weight above 1.');
    }

    @IsTest
    static void positiveSignalCreditsTheScoreThroughTheSameFormula() {
        // Escalation removed 100, expansion added 45 -> net penalty 55.
        RIQ_HealthScoreService.ScoreResult result = score(
            new List<RIQ_Health_Signal__c>{
                signal('Support Escalation', 4, TODAY),
                signal('Positive Expansion', 3, TODAY)
            },
            null
        );

        System.assertEquals(45, result.score);
        System.assert(
            result.drivers[1].explanation.contains('added'),
            'A negative weight is reported as points added, not a separate code path.'
        );
    }

    @IsTest
    static void positiveSignalsCannotPushTheScoreAboveOneHundred() {
        RIQ_HealthScoreService.ScoreResult result = score(
            new List<RIQ_Health_Signal__c>{ signal('Positive Expansion', 5, TODAY) },
            null
        );

        System.assertEquals(100, result.score);
    }

    @IsTest
    static void manySignalsClampAtZero() {
        List<RIQ_Health_Signal__c> signals = new List<RIQ_Health_Signal__c>();

        for (Integer i = 0; i < 5; i++) {
            signals.add(signal('Support Escalation', 5, TODAY));
        }

        System.assertEquals(0, score(signals, null).score);
    }

    @IsTest
    static void weightOverrideReplacesTheConfiguredBaseWeight() {
        RIQ_Health_Signal__c overridden = signal('Support Escalation', 2, TODAY);
        overridden.Weight_Override__c = 10;

        System.assertEquals(80, score(new List<RIQ_Health_Signal__c>{ overridden }, null).score);
    }

    @IsTest
    static void blankSeverityIsTreatedAsMinimumSeverity() {
        RIQ_HealthScoreService.ScoreResult result = score(
            new List<RIQ_Health_Signal__c>{ signal('Support Escalation', null, TODAY) },
            null
        );

        System.assertEquals(75, result.score);
        System.assertEquals(1, result.drivers[0].severity);
    }

    @IsTest
    static void severityAboveTheRangeIsClampedToFive() {
        RIQ_HealthScoreService.ScoreResult result = score(
            new List<RIQ_Health_Signal__c>{ signal('Low Product Usage', 9, TODAY) },
            null
        );

        System.assertEquals(25, result.score, '15 * 5 = 75 points, so 25 remains.');
        System.assertEquals(5, result.drivers[0].severity);
    }

    @IsTest
    static void signalTypeWithoutARuleIsIgnored() {
        RIQ_HealthScoreService.ScoreResult result = score(
            new List<RIQ_Health_Signal__c>{ signal('Late Payment', 5, TODAY) },
            null
        );

        System.assertEquals(100, result.score, 'No rule means no contribution, not a guessed weight.');
        System.assertEquals(0, result.drivers.size());
    }

    @IsTest
    static void driversReturnTheThreeBiggestImpacts() {
        List<RIQ_Health_Signal__c> signals = new List<RIQ_Health_Signal__c>{
            signal('Support Escalation', 5, TODAY), // 125
            signal('Low Product Usage', 5, TODAY), // 75
            signal('Missed QBR', 5, TODAY), // 50
            signal('Positive Expansion', 1, TODAY) // 15
        };

        RIQ_HealthScoreService.ScoreResult result = score(signals, null);

        System.assertEquals(3, result.drivers.size(), 'Only the top three are surfaced.');
        System.assertEquals('Support Escalation', result.drivers[0].signalType);
        System.assertEquals('Low Product Usage', result.drivers[1].signalType);
        System.assertEquals('Missed QBR', result.drivers[2].signalType);
    }

    @IsTest
    static void driversJsonCapturesEveryContribution() {
        List<RIQ_Health_Signal__c> signals = new List<RIQ_Health_Signal__c>{
            signal('Support Escalation', 2, TODAY),
            signal('Missed QBR', 1, TODAY)
        };

        RIQ_HealthScoreService.ScoreResult result = score(signals, null);

        System.assert(result.driversJson.contains('Support Escalation'));
        System.assert(result.driversJson.contains('Missed QBR'));
        System.assertEquals(2, ((List<Object>) JSON.deserializeUntyped(result.driversJson)).size());
    }

    @IsTest
    static void bandsAreEvaluatedHighestFirstEvenWhenUnsorted() {
        // Score 80 sits exactly on the Healthy floor.
        RIQ_HealthScoreService.ScoreResult healthy = score(
            new List<RIQ_Health_Signal__c>{ signal('Support Escalation', 1, TODAY.addDays(-18)) },
            null
        );

        System.assertEquals(80, healthy.score);
        System.assertEquals('Healthy', healthy.status);

        List<RIQ_Health_Signal__c> worse = new List<RIQ_Health_Signal__c>{
            signal('Support Escalation', 1, TODAY),
            signal('Low Product Usage', 2, TODAY),
            signal('Missed QBR', 1, TODAY)
        };

        System.assertEquals('Critical', score(worse, null).status, '35 falls below every band except Critical.');
    }

    @IsTest
    static void scoreWithoutBandsHasNoStatus() {
        RIQ_HealthScoreService.ScoreResult result = RIQ_HealthScoreService.calculate(
            new List<RIQ_Health_Signal__c>(),
            TODAY,
            null,
            RIQ_TestDataFactory.testRules(),
            new List<RIQ_HealthThreshold>()
        );

        System.assertEquals(null, result.status, 'No configuration means no band, not a hardcoded guess.');
    }

    @IsTest
    static void nullConfigurationIsTolerated() {
        RIQ_HealthScoreService.ScoreResult result = RIQ_HealthScoreService.calculate(null, null, null, null, null);

        System.assertEquals(100, result.score);
        System.assertEquals(null, result.status);
    }

    @IsTest
    static void renewalProximityRaisesChurnProbability() {
        System.assertEquals(12, RIQ_HealthScoreService.calculateChurnProbability(100, 20));
        System.assertEquals(6, RIQ_HealthScoreService.calculateChurnProbability(100, 60));
        System.assertEquals(15, RIQ_HealthScoreService.calculateChurnProbability(100, -3));
        System.assertEquals(0, RIQ_HealthScoreService.calculateChurnProbability(100, 400));
        System.assertEquals(100, RIQ_HealthScoreService.calculateChurnProbability(0, -1), 'Clamped at 100.');
    }

    @IsTest
    static void decayFactorHandlesMissingConfiguration() {
        System.assertEquals(1, RIQ_HealthScoreService.decayFactor(TODAY.addDays(-10), 0, TODAY));
        System.assertEquals(1, RIQ_HealthScoreService.decayFactor(TODAY.addDays(-10), null, TODAY));
        System.assertEquals(1, RIQ_HealthScoreService.decayFactor(null, 90, TODAY));
    }

    @IsTest
    static void scoreBelowEveryBandFallsBackToTheLowestBand() {
        RIQ_HealthScoreService.ScoreResult result = RIQ_HealthScoreService.calculate(
            new List<RIQ_Health_Signal__c>{
                signal('Support Escalation', 1, TODAY),
                signal('Low Product Usage', 2, TODAY),
                signal('Missed QBR', 1, TODAY)
            },
            TODAY,
            null,
            RIQ_TestDataFactory.testRules(),
            new List<RIQ_HealthThreshold>{
                new RIQ_HealthThreshold('Healthy', 80),
                new RIQ_HealthThreshold('Watch', 60)
            }
        );

        System.assertEquals(35, result.score);
        System.assertEquals('Watch', result.status, 'With no floor band, the lowest configured band wins.');
    }

    @IsTest
    static void severityBelowTheRangeIsClampedToOne() {
        RIQ_HealthScoreService.ScoreResult result = score(
            new List<RIQ_Health_Signal__c>{ signal('Support Escalation', 0, TODAY) },
            null
        );

        System.assertEquals(75, result.score);
        System.assertEquals(1, result.drivers[0].severity);
    }
}
