/**
 * @description The RenewalIQ scoring engine. This class is deliberately pure:
 * it takes signals plus configuration and returns a score, with no SOQL, no DML
 * and no static state. Everything else in the app (trigger, queueable, future
 * batch and LWC preview) calls the same method, so the number a CSM sees can
 * never disagree with the number that was stored.
 *
 * Formula, in one line: score = 100 - sum(baseWeight * severity * decayFactor),
 * clamped to 0..100. Positive signals are just rules with a negative
 * Base_Weight__c - there is one formula, not two code paths.
 */
public with sharing class RIQ_HealthScoreService {
    /** A brand new customer with no signals starts here. */
    public static final Integer PERFECT_SCORE = 100;
    /** How many drivers are surfaced to explain a score. */
    public static final Integer MAX_DRIVERS = 3;
    /** Highest/lowest severity the engine will honour. */
    private static final Integer MIN_SEVERITY = 1;
    private static final Integer MAX_SEVERITY = 5;
    /** Guards Drivers__c (32768 chars) against very chatty accounts. */
    private static final Integer MAX_SERIALIZED_DRIVERS = 100;

    /**
     * Churn is derived, not configured: the score drives most of it and the
     * distance to renewal adds urgency. These are algorithm constants, not
     * business thresholds - thresholds live in RIQ_Threshold__mdt.
     */
    private static final Decimal CHURN_SCORE_WEIGHT = 0.9;
    private static final Integer CHURN_BONUS_RENEWAL_OVERDUE = 15;
    private static final Integer CHURN_BONUS_RENEWAL_30_DAYS = 12;
    private static final Integer CHURN_BONUS_RENEWAL_90_DAYS = 6;

    /**
     * @description One signal's contribution to the score.
     */
    public class ScoreDriver {
        /** Signal that produced this contribution. */
        public Id signalId { get; private set; }
        /** Signal type, e.g. Support Escalation. */
        public String signalType { get; private set; }
        /** Severity after normalisation to 1..5. */
        public Integer severity { get; private set; }
        /** Points removed from the score; negative means the signal added points. */
        public Decimal points { get; private set; }
        /** Date the signal occurred. */
        public Date occurredOn { get; private set; }
        /** One-line, CSM-readable reason. */
        public String explanation { get; private set; }

        public ScoreDriver(
            Id signalId,
            String signalType,
            Integer severity,
            Decimal points,
            Date occurredOn
        ) {
            this.signalId = signalId;
            this.signalType = signalType;
            this.severity = severity;
            // Rounded for the audit payload only; the score itself uses full precision.
            this.points = points == null ? 0 : points.setScale(2, RoundingMode.HALF_UP);
            this.occurredOn = occurredOn;
            String verb = this.points >= 0 ? 'removed' : 'added';
            this.explanation =
                signalType +
                ' (severity ' +
                severity +
                ') ' +
                verb +
                ' ' +
                this.points.abs().setScale(1, RoundingMode.HALF_UP) +
                ' points';
        }
    }

    /**
     * @description Everything the caller needs to persist one recalculated score.
     */
    public class ScoreResult {
        /** Clamped health score, 0..100. */
        public Integer score { get; private set; }
        /** Band from RIQ_Threshold__mdt; null when no bands are configured. */
        public String status { get; private set; }
        /** Churn probability as a whole percent, 0..100. */
        public Integer churnProbability { get; private set; }
        /** The largest contributions, biggest absolute impact first. */
        public List<ScoreDriver> drivers { get; private set; }
        /** JSON of every contribution, stored on RIQ_Score_History__c.Drivers__c. */
        public String driversJson { get; private set; }

        public ScoreResult(
            Integer score,
            String status,
            Integer churnProbability,
            List<ScoreDriver> drivers,
            String driversJson
        ) {
            this.score = score;
            this.status = status;
            this.churnProbability = churnProbability;
            this.drivers = drivers;
            this.driversJson = driversJson;
        }
    }

    /**
     * @description Calculates a health score from signals and configuration.
     * @param signals Health signals for one account. Null is treated as none.
     * @param asOf Date to age signals against; defaults to today.
     * @param daysToRenewal Days until contract end; null when unknown, negative
     *        when the renewal date has passed.
     * @param rules Active scoring rules keyed by signal type. Signal types with
     *        no rule contribute nothing.
     * @param thresholds Status bands; sorted internally, so order does not matter.
     * @return The score, its band, churn probability and drivers.
     */
    public static ScoreResult calculate(
        List<RIQ_Health_Signal__c> signals,
        Date asOf,
        Integer daysToRenewal,
        Map<String, RIQ_ScoringRule> rules,
        List<RIQ_HealthThreshold> thresholds
    ) {
        Date scoringDate = asOf == null ? Date.today() : asOf;
        Map<String, RIQ_ScoringRule> activeRules = rules == null ? new Map<String, RIQ_ScoringRule>() : rules;

        Decimal totalPenalty = 0;
        List<ScoreDriver> contributions = new List<ScoreDriver>();

        if (signals != null) {
            for (RIQ_Health_Signal__c signal : signals) {
                RIQ_ScoringRule rule = activeRules.get(signal.Signal_Type__c);

                if (rule == null) {
                    continue;
                }

                Decimal decay = decayFactor(signal.Occurred_On__c, rule.decayDays, scoringDate);

                if (decay == 0) {
                    // Fully aged out: it no longer explains the score either.
                    continue;
                }

                Decimal weight = signal.Weight_Override__c != null ? signal.Weight_Override__c : rule.baseWeight;
                Integer severity = normaliseSeverity(signal.Severity__c);
                Decimal points = weight * severity * decay;

                totalPenalty += points;
                contributions.add(
                    new ScoreDriver(signal.Id, signal.Signal_Type__c, severity, points, signal.Occurred_On__c)
                );
            }
        }

        Integer score = clampToPercent(PERFECT_SCORE - totalPenalty);

        return new ScoreResult(
            score,
            resolveStatus(score, thresholds),
            calculateChurnProbability(score, daysToRenewal),
            topDrivers(contributions),
            serializeDrivers(contributions)
        );
    }

    /**
     * @description Linear decay: full weight on the day a signal occurs, zero
     * once Decay_Days has passed. A rule with no decay window is always full
     * weight, which is how "this never fades" is configured.
     * @param occurredOn Date the signal occurred.
     * @param decayDays Configured decay window.
     * @param asOf Date being scored.
     * @return Multiplier between 0 and 1.
     */
    public static Decimal decayFactor(Date occurredOn, Integer decayDays, Date asOf) {
        if (decayDays == null || decayDays <= 0 || occurredOn == null) {
            return 1;
        }

        Integer age = occurredOn.daysBetween(asOf);

        if (age <= 0) {
            // Same day, or a future-dated signal: never amplify above full weight.
            return 1;
        }

        if (age >= decayDays) {
            return 0;
        }

        return (Decimal.valueOf(decayDays) - age) / decayDays;
    }

    /**
     * @description Converts a score into a whole-percent churn probability. The
     * score carries most of the weight; an imminent or overdue renewal adds
     * urgency, because a healthy account renewing next month is still a decision
     * that has to be made now.
     * @param score Health score 0..100.
     * @param daysToRenewal Days until contract end; null when unknown.
     * @return Churn probability 0..100.
     */
    public static Integer calculateChurnProbability(Integer score, Integer daysToRenewal) {
        Decimal churnedRisk = (PERFECT_SCORE - score) * CHURN_SCORE_WEIGHT;
        Integer urgencyBonus = 0;

        if (daysToRenewal != null) {
            if (daysToRenewal <= 0) {
                urgencyBonus = CHURN_BONUS_RENEWAL_OVERDUE;
            } else if (daysToRenewal <= 30) {
                urgencyBonus = CHURN_BONUS_RENEWAL_30_DAYS;
            } else if (daysToRenewal <= 90) {
                urgencyBonus = CHURN_BONUS_RENEWAL_90_DAYS;
            }
        }

        return clampToPercent(churnedRisk + urgencyBonus);
    }

    /**
     * @description Maps a score onto a status band. Bands are evaluated highest
     * Min_Score first, so a score of 80 falls into Healthy even when the bands
     * arrive unsorted. A score below every band takes the lowest band.
     * @param score Health score 0..100.
     * @param thresholds Configured bands, any order.
     * @return Band label, or null when no bands are configured.
     */
    public static String resolveStatus(Integer score, List<RIQ_HealthThreshold> thresholds) {
        if (thresholds == null || thresholds.isEmpty()) {
            return null;
        }

        List<RIQ_HealthThreshold> sorted = new List<RIQ_HealthThreshold>(thresholds);
        sortThresholdsDescending(sorted);

        for (RIQ_HealthThreshold band : sorted) {
            if (score >= band.minScore) {
                return band.status;
            }
        }

        return sorted[sorted.size() - 1].status;
    }

    /**
     * @description Severity is user-entered data, so it is normalised rather than
     * trusted: blank becomes the minimum, out-of-range values are clamped.
     * @param severity Raw severity from the signal.
     * @return Severity between 1 and 5.
     */
    private static Integer normaliseSeverity(Decimal severity) {
        if (severity == null) {
            return MIN_SEVERITY;
        }

        Integer rounded = severity.setScale(0, RoundingMode.HALF_UP).intValue();

        if (rounded < MIN_SEVERITY) {
            return MIN_SEVERITY;
        }

        return rounded > MAX_SEVERITY ? MAX_SEVERITY : rounded;
    }

    /**
     * @description Picks the three signals that moved the score most, in either
     * direction, so "your score dropped 30 points" always has an explanation.
     * @param contributions Every signal that contributed.
     * @return Up to MAX_DRIVERS drivers, largest absolute impact first.
     */
    private static List<ScoreDriver> topDrivers(List<ScoreDriver> contributions) {
        List<ScoreDriver> ranked = new List<ScoreDriver>(contributions);
        sortByMagnitudeDescending(ranked);

        List<ScoreDriver> top = new List<ScoreDriver>();

        for (Integer i = 0; i < ranked.size() && i < MAX_DRIVERS; i++) {
            top.add(ranked[i]);
        }

        return top;
    }

    /**
     * @param contributions Every signal that contributed.
     * @return JSON payload for RIQ_Score_History__c.Drivers__c.
     */
    private static String serializeDrivers(List<ScoreDriver> contributions) {
        List<ScoreDriver> capped = new List<ScoreDriver>();

        for (Integer i = 0; i < contributions.size() && i < MAX_SERIALIZED_DRIVERS; i++) {
            capped.add(contributions[i]);
        }

        return JSON.serialize(capped);
    }

    /**
     * @description Insertion sort: Apex has no Comparator, and the driver list is
     * at most a few dozen entries, so O(n^2) is irrelevant here.
     * @param drivers Drivers to sort in place, largest absolute points first.
     */
    private static void sortByMagnitudeDescending(List<ScoreDriver> drivers) {
        for (Integer i = 1; i < drivers.size(); i++) {
            ScoreDriver current = drivers[i];
            Integer j = i - 1;

            while (j >= 0 && drivers[j].points.abs() < current.points.abs()) {
                drivers[j + 1] = drivers[j];
                j--;
            }

            drivers[j + 1] = current;
        }
    }

    /**
     * @param bands Thresholds to sort in place, highest Min_Score first.
     */
    private static void sortThresholdsDescending(List<RIQ_HealthThreshold> bands) {
        for (Integer i = 1; i < bands.size(); i++) {
            RIQ_HealthThreshold current = bands[i];
            Integer j = i - 1;

            while (j >= 0 && bands[j].minScore < current.minScore) {
                bands[j + 1] = bands[j];
                j--;
            }

            bands[j + 1] = current;
        }
    }

    /**
     * @param value Points value before clamping.
     * @return Whole number 0..100.
     */
    private static Integer clampToPercent(Decimal value) {
        Integer rounded = value.setScale(0, RoundingMode.HALF_UP).intValue();

        if (rounded < 0) {
            return 0;
        }

        return rounded > PERFECT_SCORE ? PERFECT_SCORE : rounded;
    }
}
