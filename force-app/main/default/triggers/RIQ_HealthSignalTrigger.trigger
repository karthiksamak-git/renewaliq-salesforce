/**
 * @description The only trigger on RIQ_Health_Signal__c. Contains no logic: all
 * behaviour lives in RIQ_HealthSignalTriggerHandler so it can be unit tested
 * without DML and reused from other entry points.
 */
trigger RIQ_HealthSignalTrigger on RIQ_Health_Signal__c(after insert, after update, after delete, after undelete) {
    new RIQ_HealthSignalTriggerHandler().run();
}
