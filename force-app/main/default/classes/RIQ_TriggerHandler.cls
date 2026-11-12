/**
 * @description Base class for every RenewalIQ trigger handler. Triggers contain no
 * logic: they instantiate a handler and call run(). This class owns the three
 * cross-cutting concerns every handler needs - dispatch, a per-transaction
 * bypass mechanism, and a recursion guard - so no handler re-implements them.
 *
 * The bypass and recursion state are static, which means they live for exactly
 * one transaction. Nothing leaks between requests, and tests start clean.
 */
public virtual class RIQ_TriggerHandler {
    /** Handlers explicitly bypassed for the rest of this transaction. */
    private static final Set<String> BYPASSED_HANDLERS = new Set<String>();

    /**
     * Handlers currently on the stack. A handler that writes to an object it
     * also handles would re-enter itself; this Set stops that at depth one.
     */
    private static final Set<String> EXECUTING_HANDLERS = new Set<String>();

    /** Derived from the runtime class name, e.g. RIQ_HealthSignalTriggerHandler. */
    private final String handlerName;

    public RIQ_TriggerHandler() {
        this.handlerName = String.valueOf(this).substringBefore(':');
    }

    /**
     * @description Entry point called by the trigger. Resolves the current
     * trigger operation and dispatches to the matching virtual method exactly
     * once per transaction.
     */
    public void run() {
        if (!Trigger.isExecuting || isBypassed() || EXECUTING_HANDLERS.contains(handlerName)) {
            return;
        }

        EXECUTING_HANDLERS.add(handlerName);
        try {
            execute(Trigger.operationType);
        } finally {
            // Removed in finally so a thrown exception cannot poison the guard
            // for the rest of the transaction.
            EXECUTING_HANDLERS.remove(handlerName);
        }
    }

    /**
     * @description Dispatches to the matching lifecycle method. Separated from
     * run() so tests can drive every branch with an explicit operation instead
     * of needing seven different triggers.
     * @param operation The trigger operation to dispatch.
     */
    public void execute(System.TriggerOperation operation) {
        if (operation == null) {
            return;
        }

        switch on operation {
            when BEFORE_INSERT {
                beforeInsert();
            }
            when BEFORE_UPDATE {
                beforeUpdate();
            }
            when BEFORE_DELETE {
                beforeDelete();
            }
            when AFTER_INSERT {
                afterInsert();
            }
            when AFTER_UPDATE {
                afterUpdate();
            }
            when AFTER_DELETE {
                afterDelete();
            }
            when AFTER_UNDELETE {
                afterUndelete();
            }
        }
    }

    /**
     * @description Stops a handler from running for the rest of the transaction.
     * Used by data loads, migrations and tests that must not fan out into
     * scoring or callouts.
     * @param handlerName Class name of the handler to bypass.
     */
    public static void bypass(String handlerName) {
        if (String.isNotBlank(handlerName)) {
            BYPASSED_HANDLERS.add(handlerName);
        }
    }

    /**
     * @description Re-enables every bypassed handler in this transaction.
     */
    public static void clearBypass() {
        BYPASSED_HANDLERS.clear();
    }

    /**
     * @description Reports whether a handler is currently bypassed.
     * @param handlerName Class name of the handler to check.
     * @return True when the handler is bypassed.
     */
    public static Boolean isBypassed(String handlerName) {
        return BYPASSED_HANDLERS.contains(handlerName);
    }

    /**
     * @description Reports whether this handler is bypassed.
     * @return True when this handler is bypassed.
     */
    public Boolean isBypassed() {
        return isBypassed(handlerName);
    }

    protected virtual void beforeInsert() {
    }

    protected virtual void beforeUpdate() {
    }

    protected virtual void beforeDelete() {
    }

    protected virtual void afterInsert() {
    }

    protected virtual void afterUpdate() {
    }

    protected virtual void afterDelete() {
    }

    protected virtual void afterUndelete() {
    }
}
