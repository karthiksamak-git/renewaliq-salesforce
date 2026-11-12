/**
 * @description In-memory value object for one status band. Bands are matched
 * from the highest Min_Score downwards, so the order the provider returns is
 * not load bearing - the engine sorts defensively.
 */
public class RIQ_HealthThreshold {
    /** Status label, e.g. Healthy. */
    public final String status;
    /** Lowest score that still falls in this band. */
    public final Integer minScore;

    /**
     * @param status Status label this band maps to.
     * @param minScore Lowest inclusive score in the band.
     */
    public RIQ_HealthThreshold(String status, Integer minScore) {
        this.status = status;
        this.minScore = minScore == null ? 0 : minScore;
    }
}
