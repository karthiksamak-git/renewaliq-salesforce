/**
 * @description Subscriber for RIQ_Log_Event__e. Contains no logic: it hands the
 * delivered events to RIQ_Logger.persist so the mapping is unit tested without
 * needing a real publish.
 *
 * This trigger runs in its own transaction, which is the point: a log written
 * inside a transaction that later rolls back still gets stored.
 */
trigger RIQ_LogEventTrigger on RIQ_Log_Event__e(after insert) {
    RIQ_Logger.persist(Trigger.new);
}
