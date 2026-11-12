/**
 * @description The only trigger on RIQ_Health_Status_Change__e. Platform event
 * triggers cannot use the standard handler's Trigger.isExecuting guard path
 * meaningfully, so this one delegates straight to the service, exactly like
 * every other trigger in the app.
 *
 * Runs as the named user in RIQ_HealthStatusChangeSubscriber rather than
 * "Automated Process" so the Tasks and Opportunities it creates have a real,
 * auditable owner context.
 */
trigger RIQ_HealthStatusChangeTrigger on RIQ_Health_Status_Change__e(after insert) {
    RIQ_PlaybookService.run(Trigger.new);
}
