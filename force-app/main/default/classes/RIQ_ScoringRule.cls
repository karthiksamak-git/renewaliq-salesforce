/**
 * @description In-memory value object for one configured scoring rule. The
 * engine consumes these instead of Custom Metadata records directly, which is
 * what makes RIQ_HealthScoreService a pure function that can be unit tested
 * without touching configuration.
 */
public class RIQ_ScoringRule {
    /** Signal type this rule applies to. */
    public final String signalType;
    /** Points removed from a perfect score at full severity. Negative is a credit. */
    public final Decimal baseWeight;
    /** Days over which the contribution fades to zero. Zero disables decay. */
    public final Integer decayDays;

    /**
     * @param signalType Signal type this rule applies to.
     * @param baseWeight Base weight, negative for credits.
     * @param decayDays Decay window in days.
     */
    public RIQ_ScoringRule(String signalType, Decimal baseWeight, Integer decayDays) {
        this.signalType = signalType;
        this.baseWeight = baseWeight == null ? 0 : baseWeight;
        this.decayDays = decayDays == null ? 0 : decayDays;
    }
}
