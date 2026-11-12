/**
 * @description Turns health signal changes into a single queued score
 * recalculation per transaction. The handler never calculates a score itself:
 * it collects the unique Accounts whose inputs changed and hands them to
 * RIQ_HealthScoreRecalculator, which keeps trigger time to zero SOQL and zero
 * DML against Account.
 */
public with sharing class RIQ_HealthSignalTriggerHandler extends RIQ_TriggerHandler {
    /**
     * @description New signals make an account's inputs stale.
     */
    protected override void afterInsert() {
        enqueueRecalculation(collectAccountIds(Trigger.new));
    }

    /**
     * @description Only updates that change a scoring input are worth a
     * recalculation. Editing Notes alone must not burn a queueable job.
     */
    protected override void afterUpdate() {
        Set<Id> affectedAccountIds = new Set<Id>();

        for (Integer i = 0; i < Trigger.new.size(); i++) {
            RIQ_Health_Signal__c updatedSignal = (RIQ_Health_Signal__c) Trigger.new[i];
            RIQ_Health_Signal__c oldSignal = (RIQ_Health_Signal__c) Trigger.old[i];

            if (isScoreAffectingChange(oldSignal, updatedSignal)) {
                affectedAccountIds.add(updatedSignal.Account__c);
            }
        }

        enqueueRecalculation(affectedAccountIds);
    }

    /**
     * @description Removing a signal can only raise a score, so the account has
     * to be recalculated too.
     */
    protected override void afterDelete() {
        enqueueRecalculation(collectAccountIds(Trigger.old));
    }

    /**
     * @description A restored signal lowers the score again.
     */
    protected override void afterUndelete() {
        enqueueRecalculation(collectAccountIds(Trigger.new));
    }

    /**
     * @description Enqueues one recalculation job for the whole transaction.
     * The set of ids is deduplicated, so a 200 signal insert produces one job,
     * not 200 - that is what keeps the org inside the queueable limit.
     * @param accountIds Unique Account ids touched by this transaction.
     */
    private static void enqueueRecalculation(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) {
            return;
        }

        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            // Nothing safe left to do inline. RIQ_NightlyScoreBatch re-scores
            // the whole book every night, so the data self-heals instead of
            // silently rotting.
            System.debug(
                LoggingLevel.WARN,
                'RenewalIQ: queueable limit reached, skipped score recalculation for ' + accountIds.size() + ' account(s).'
            );
            return;
        }

        System.enqueueJob(new RIQ_HealthScoreRecalculator(accountIds));
    }

    /**
     * @description Collects the distinct Account ids from a trigger context.
     * @param signals Trigger.new or Trigger.old.
     * @return Unique Account ids, never null.
     */
    private static Set<Id> collectAccountIds(List<RIQ_Health_Signal__c> signals) {
        Set<Id> accountIds = new Set<Id>();

        if (signals == null) {
            return accountIds;
        }

        for (RIQ_Health_Signal__c signal : signals) {
            if (signal.Account__c != null) {
                accountIds.add(signal.Account__c);
            }
        }

        return accountIds;
    }

    /**
     * @description Compares just the fields the scoring engine reads.
     * @param oldSignal The record before the update.
     * @param updatedSignal The record after the update.
     * @return True when at least one scoring input changed.
     */
    private static Boolean isScoreAffectingChange(RIQ_Health_Signal__c oldSignal, RIQ_Health_Signal__c updatedSignal) {
        return oldSignal.Account__c != updatedSignal.Account__c ||
            oldSignal.Signal_Type__c != updatedSignal.Signal_Type__c ||
            oldSignal.Severity__c != updatedSignal.Severity__c ||
            oldSignal.Occurred_On__c != updatedSignal.Occurred_On__c ||
            oldSignal.Weight_Override__c != updatedSignal.Weight_Override__c;
    }
}
