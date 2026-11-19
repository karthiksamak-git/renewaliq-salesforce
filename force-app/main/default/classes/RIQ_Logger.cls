/**
 * @description The one logging entry point in RenewalIQ.
 *
 * Why a platform event rather than a direct insert: a log line is most valuable
 * exactly when the transaction is about to fail, and a normal DML insert is
 * rolled back with everything else. RIQ_Log_Event__e is defined with the
 * Publish Immediately behaviour, so the message is published when the publish
 * call executes and cannot be rolled back; the subscriber trigger writes
 * RIQ_Log__c in its own transaction. Salesforce documents this pattern for
 * logging for the same reason.
 *
 * Three rules keep the log trustworthy:
 *
 * 1. It never throws. A logging call inside a catch block that itself fails
 *    would replace the real error with a useless one, so every failure here
 *    degrades to System.debug.
 * 2. It never stores what it should not: API keys, bearer tokens, email
 *    addresses and phone numbers are redacted before the message leaves the
 *    transaction. Signal notes are free text and are never passed in. Payload
 *    text is capped at 255 characters, which is the platform event field limit.
 * 3. It never reads business data, so it runs without sharing on purpose - a
 *    log line about a record the running user cannot see is still a log line
 *    this admin needs. It performs no SOQL at all.
 */
public without sharing class RIQ_Logger {
    /** Level value for a failure that needs an administrator. */
    public static final String LEVEL_ERROR = 'Error';
    /** Level value for a degraded but handled condition. */
    public static final String LEVEL_WARNING = 'Warning';
    /** Level value for a routine operational fact. */
    public static final String LEVEL_INFO = 'Info';

    /**
     * Message budget. Platform event text fields cap at 255 characters, so the
     * payload is bounded here rather than silently cut by the platform. Write a
     * one-line message; the detail belongs in the stack.
     */
    public static final Integer MAX_MESSAGE_LENGTH = 255;
    /** Source budget: the Source__c field is 120 characters. */
    public static final Integer MAX_SOURCE_LENGTH = 120;
    /**
     * Stack budget, also capped by the 255 character platform event text field.
     * getStackTraceString() starts at the innermost frame, so a cut keeps the
     * line that actually failed.
     */
    public static final Integer MAX_STACK_LENGTH = 255;
    /** Related id budget: the Related_Id__c field is 18 characters. */
    public static final Integer MAX_RELATED_ID_LENGTH = 18;

    /**
     * Stop publishing while this many of the 150 Publish Immediately calls are
     * still available. A nightly run that logs per chunk must not turn a limit
     * breach into a second failure.
     */
    private static final Integer PUBLISH_HEADROOM = 5;

    /** Provider keys: Groq, OpenAI, Anthropic and Slack token prefixes. */
    private static final Pattern KEY_PATTERN = Pattern.compile(
        '(?i)(gsk_|sk-ant-|sk-proj-|sk-live-|sk-test-|sk_|xox[baprs]-)[a-z0-9_\\-]{6,}'
    );
    /** "Authorization: Bearer abc..." captured whole. */
    private static final Pattern BEARER_PATTERN = Pattern.compile('(?i)bearer\\s+[a-z0-9._~+/=\\-]{6,}');
    /** key=value / password: value style secrets. */
    private static final Pattern ASSIGNED_SECRET_PATTERN = Pattern.compile(
        '(?i)(api[_-]?key|apikey|secret|password|passwd|token|client_secret)\\s*[=:]\\s*[^\\s,;"\'&]{3,}'
    );
    /** Ordinary email addresses. */
    private static final Pattern EMAIL_PATTERN = Pattern.compile('[a-z0-9._%+\\-]+@[a-z0-9.\\-]+\\.[a-z]{2,}');
    /** Long digit runs and international numbers. */
    private static final Pattern PHONE_PATTERN = Pattern.compile('(\\+\\d[\\d\\s\\-]{8,}\\d|\\b\\d{10,}\\b)');

    /**
     * @param source Short class or component name, e.g. RIQ_NightlyScoreBatch.
     * @param message What happened, in plain language.
     */
    public static void error(String source, String message) {
        log(LEVEL_ERROR, source, message, null, null);
    }

    /**
     * @param source Short class or component name.
     * @param message What happened, in plain language.
     * @param failure The exception being handled.
     */
    public static void error(String source, String message, Exception failure) {
        log(LEVEL_ERROR, source, message, failure, null);
    }

    /**
     * @param source Short class or component name.
     * @param message What happened, in plain language.
     * @param failure The exception being handled.
     * @param relatedId Account, job or record id the line is about.
     */
    public static void error(String source, String message, Exception failure, String relatedId) {
        log(LEVEL_ERROR, source, message, failure, relatedId);
    }

    /**
     * @param source Short class or component name.
     * @param message What was degraded.
     */
    public static void warn(String source, String message) {
        log(LEVEL_WARNING, source, message, null, null);
    }

    /**
     * @param source Short class or component name.
     * @param message What was degraded.
     * @param failure The exception being handled.
     */
    public static void warn(String source, String message, Exception failure) {
        log(LEVEL_WARNING, source, message, failure, null);
    }

    /**
     * @param source Short class or component name.
     * @param message What was degraded.
     * @param relatedId Account, job or record id the line is about.
     */
    public static void warn(String source, String message, String relatedId) {
        log(LEVEL_WARNING, source, message, null, relatedId);
    }

    /**
     * @param source Short class or component name.
     * @param message The operational fact.
     */
    public static void info(String source, String message) {
        log(LEVEL_INFO, source, message, null, null);
    }

    /**
     * @param source Short class or component name.
     * @param message The operational fact.
     * @param relatedId Account, job or record id the line is about.
     */
    public static void info(String source, String message, String relatedId) {
        log(LEVEL_INFO, source, message, null, relatedId);
    }

    /**
     * @description Builds one event and publishes it. Private so the only way
     * to log is through a named level, and total in the sense that it cannot
     * throw: a publish failure becomes a debug line.
     * @param level Error, Warning or Info.
     * @param source Short class or component name.
     * @param message What happened.
     * @param failure Exception being handled, or null.
     * @param relatedId Account, job or record id, or null.
     */
    private static void log(String level, String source, String message, Exception failure, String relatedId) {
        String safeMessage = redactSecrets(message, MAX_MESSAGE_LENGTH);
        String safeSource = clamp(source, MAX_SOURCE_LENGTH);
        String safeStack = failure == null
            ? null
            : redactSecrets(failure.getTypeName() + ': ' + failure.getStackTraceString(), MAX_STACK_LENGTH);

        if (remainingPublishCalls() <= 0) {
            System.debug( // NOPMD AvoidDebugStatements: last-resort path, no publish budget left.
                LoggingLevel.ERROR,
                'RenewalIQ log (' + safeSource + '): ' + safeMessage + ' [not persisted: publish limit]'
            );
            return;
        }

        try {
            EventBus.publish(
                new RIQ_Log_Event__e(
                    Level__c = level,
                    Source__c = safeSource,
                    Message__c = safeMessage,
                    Stack_Trace__c = safeStack,
                    Related_Id__c = clamp(relatedId, MAX_RELATED_ID_LENGTH),
                    Logged_At__c = DateTime.now()
                )
            );
        } catch (Exception publishFailure) {
            System.debug( // NOPMD AvoidDebugStatements: the logger has nowhere else to report this.
                LoggingLevel.ERROR,
                'RenewalIQ log (' +
                    safeSource +
                    '): ' +
                    safeMessage +
                    ' [not persisted: ' +
                    publishFailure.getMessage() +
                    ']'
            );
        }
    }

    /**
     * @param events Delivered RIQ_Log_Event__e records.
     * @description Subscriber work: copies the event payload onto RIQ_Log__c.
     *
     * SYSTEM_MODE on purpose. The subscriber runs as the Automated Process user,
     * which holds no RenewalIQ permission set, and the whole point of the log is
     * to record a failure the running user may not even be allowed to read. No
     * user input is interpreted as a query here, and the payload is already
     * redacted by log().
     * @param events Events from the trigger context.
     */
    public static void persist(List<RIQ_Log_Event__e> events) {
        if (events == null || events.isEmpty()) {
            return;
        }

        List<RIQ_Log__c> rows = new List<RIQ_Log__c>();

        for (RIQ_Log_Event__e event : events) {
            rows.add(
                new RIQ_Log__c(
                    Level__c = event.Level__c,
                    Source__c = clamp(event.Source__c, MAX_SOURCE_LENGTH),
                    Message__c = clamp(event.Message__c, MAX_MESSAGE_LENGTH),
                    Stack_Trace__c = clamp(event.Stack_Trace__c, MAX_STACK_LENGTH),
                    Related_Id__c = clamp(event.Related_Id__c, MAX_RELATED_ID_LENGTH),
                    Logged_At__c = event.Logged_At__c == null ? DateTime.now() : event.Logged_At__c
                )
            );
        }

        try {
            Database.insert(rows, false, AccessLevel.SYSTEM_MODE);
        } catch (Exception writeFailure) {
            System.debug(LoggingLevel.ERROR, 'RenewalIQ log write failed for ' + rows.size() + ' row(s).'); // NOPMD nothing left to log to
        }
    }

    /**
     * @description Redacts secrets and personal data, then truncates. Public and
     * test-visible because the redaction rules are the part of this class that
     * most deserves a test.
     * @param value Raw text.
     * @param maxLength Maximum length to keep.
     * @return Safe, bounded text; null stays null.
     */
    @TestVisible
    public static String redactSecrets(String value, Integer maxLength) {
        if (String.isBlank(value)) {
            return value;
        }

        // Bound the text before running any pattern. Regex over a multi-kilobyte
        // message is how a logging call turns into "Regex too complicated", and
        // only the first maxLength characters are ever stored anyway.
        String bounded = value.length() <= maxLength * 2 ? value : value.substring(0, maxLength * 2);
        String redacted = KEY_PATTERN.matcher(bounded).replaceAll('[redacted key]');
        redacted = BEARER_PATTERN.matcher(redacted).replaceAll('[redacted token]');
        redacted = ASSIGNED_SECRET_PATTERN.matcher(redacted).replaceAll('$1=[redacted]');
        redacted = EMAIL_PATTERN.matcher(redacted).replaceAll('[redacted email]');
        redacted = PHONE_PATTERN.matcher(redacted).replaceAll('[redacted number]');
        return clamp(redacted, maxLength);
    }

    /**
     * @return How many Publish Immediately calls are still safe to use.
     */
    private static Integer remainingPublishCalls() {
        return Limits.getLimitPublishImmediateDML() - Limits.getPublishImmediateDML() - PUBLISH_HEADROOM;
    }

    /**
     * @param value Text to bound.
     * @param maxLength Maximum length.
     * @return The text, shortened with an ellipsis when needed.
     */
    private static String clamp(String value, Integer maxLength) {
        if (value == null || value.length() <= maxLength) {
            return value;
        }

        return value.abbreviate(maxLength);
    }
}
