/**
 * @description Proves the base handler dispatches every operation exactly once,
 * that bypass works, and that run() is a no-op outside a trigger transaction.
 */
@IsTest
private class RIQ_TriggerHandler_Test {
    /**
     * @description Records which lifecycle method was invoked.
     */
    private class ProbeHandler extends RIQ_TriggerHandler {
        public Integer beforeInsertCalls = 0;
        public Integer beforeUpdateCalls = 0;
        public Integer beforeDeleteCalls = 0;
        public Integer afterInsertCalls = 0;
        public Integer afterUpdateCalls = 0;
        public Integer afterDeleteCalls = 0;
        public Integer afterUndeleteCalls = 0;

        protected override void beforeInsert() {
            beforeInsertCalls++;
        }

        protected override void beforeUpdate() {
            beforeUpdateCalls++;
        }

        protected override void beforeDelete() {
            beforeDeleteCalls++;
        }

        protected override void afterInsert() {
            afterInsertCalls++;
        }

        protected override void afterUpdate() {
            afterUpdateCalls++;
        }

        protected override void afterDelete() {
            afterDeleteCalls++;
        }

        protected override void afterUndelete() {
            afterUndeleteCalls++;
        }

        public Integer totalCalls() {
            return beforeInsertCalls +
                beforeUpdateCalls +
                beforeDeleteCalls +
                afterInsertCalls +
                afterUpdateCalls +
                afterDeleteCalls +
                afterUndeleteCalls;
        }
    }

    @IsTest
    static void dispatchesEachOperationToItsOwnMethod() {
        ProbeHandler probe = new ProbeHandler();

        probe.execute(TriggerOperation.BEFORE_INSERT);
        probe.execute(TriggerOperation.BEFORE_UPDATE);
        probe.execute(TriggerOperation.BEFORE_DELETE);
        probe.execute(TriggerOperation.AFTER_INSERT);
        probe.execute(TriggerOperation.AFTER_UPDATE);
        probe.execute(TriggerOperation.AFTER_DELETE);
        probe.execute(TriggerOperation.AFTER_UNDELETE);

        System.assertEquals(1, probe.beforeInsertCalls);
        System.assertEquals(1, probe.beforeUpdateCalls);
        System.assertEquals(1, probe.beforeDeleteCalls);
        System.assertEquals(1, probe.afterInsertCalls);
        System.assertEquals(1, probe.afterUpdateCalls);
        System.assertEquals(1, probe.afterDeleteCalls);
        System.assertEquals(1, probe.afterUndeleteCalls);
        System.assertEquals(7, probe.totalCalls());
    }

    /**
     * @description A handler that implements nothing at all: the base class
     * defaults must be safe no-ops for every operation.
     */
    private class SilentHandler extends RIQ_TriggerHandler {
    }

    @IsTest
    static void baseDefaultsAreNoOps() {
        SilentHandler silent = new SilentHandler();

        silent.execute(TriggerOperation.BEFORE_INSERT);
        silent.execute(TriggerOperation.BEFORE_UPDATE);
        silent.execute(TriggerOperation.BEFORE_DELETE);
        silent.execute(TriggerOperation.AFTER_INSERT);
        silent.execute(TriggerOperation.AFTER_UPDATE);
        silent.execute(TriggerOperation.AFTER_DELETE);
        silent.execute(TriggerOperation.AFTER_UNDELETE);

        System.assertNotEquals(null, silent, 'Every operation is callable without an override.');
    }

    @IsTest
    static void nullOperationIsIgnored() {
        ProbeHandler probe = new ProbeHandler();
        probe.execute(null);

        System.assertEquals(0, probe.totalCalls());
    }

    @IsTest
    static void runOutsideATriggerDoesNothing() {
        ProbeHandler probe = new ProbeHandler();
        probe.run();

        System.assertEquals(0, probe.totalCalls(), 'run() must not dispatch when Trigger.isExecuting is false.');
    }

    @IsTest
    static void bypassIsVisibleAndReversible() {
        RIQ_TriggerHandler.clearBypass();
        System.assertEquals(false, RIQ_TriggerHandler.isBypassed('RIQ_Probe'));

        RIQ_TriggerHandler.bypass('RIQ_Probe');
        System.assertEquals(true, RIQ_TriggerHandler.isBypassed('RIQ_Probe'));

        RIQ_TriggerHandler.clearBypass();
        System.assertEquals(false, RIQ_TriggerHandler.isBypassed('RIQ_Probe'));
    }

    @IsTest
    static void blankBypassNameIsIgnored() {
        RIQ_TriggerHandler.clearBypass();
        RIQ_TriggerHandler.bypass(null);
        RIQ_TriggerHandler.bypass('');

        System.assertEquals(false, RIQ_TriggerHandler.isBypassed(null));
        System.assertEquals(false, RIQ_TriggerHandler.isBypassed(''));
    }
}
