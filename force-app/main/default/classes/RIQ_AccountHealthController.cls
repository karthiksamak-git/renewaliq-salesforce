/**
 * @description Backs the Account health card and the signal logger.
 *
 * Read methods are cacheable; recalculate() and logSignal() are not, because
 * they change state - the client must always go to the server for those.
 *
 * Authorisation is enforced here, not by hiding buttons. Editing rights come
 * from Custom Permissions (RIQ_Recalculate_Health, RIQ_Log_Health_Signals) that
 * only RIQ_Admin and RIQ_CSM hold, so a Read-Only user calling the Apex directly
 * is refused even though the component would have hidden the button.
 */
public with sharing class RIQ_AccountHealthController {
    /** History points returned to the sparkline. */
    public static final Integer TREND_POINTS = 12;
    /** Highest/lowest severity a signal may carry. */
    private static final Integer MIN_SEVERITY = 1;
    private static final Integer MAX_SEVERITY = 5;
    /** Guard against a huge Drivers__c payload being re-serialised to the client. */
    private static final Integer MAX_DRIVERS = 5;
    /** Signal notes are free text; the field is 5000 characters, so refuse more. */
    private static final Integer MAX_NOTES_LENGTH = 5000;

    /** One scoring driver, parsed from RIQ_Score_History__c.Drivers__c. */
    public class Driver {
        /** Signal type, e.g. Support Escalation. */
        @AuraEnabled
        public String signalType;
        /** Severity 1..5. */
        @AuraEnabled
        public Integer severity;
        /** Points removed (negative means added). */
        @AuraEnabled
        public Decimal points;
        /** When the signal occurred. */
        @AuraEnabled
        public Date occurredOn;
        /** CSM-readable explanation. */
        @AuraEnabled
        public String explanation;
    }

    /** One point of the trend line. */
    public class HistoryPoint {
        /** When the score was calculated. */
        @AuraEnabled
        public DateTime calculatedOn;
        /** Score at that moment. */
        @AuraEnabled
        public Integer score;
        /** Band at that moment. */
        @AuraEnabled
        public String status;
    }

    /** Everything the score card renders. */
    public class HealthCard {
        /** Account id. */
        @AuraEnabled
        public Id accountId;
        /** Account name. */
        @AuraEnabled
        public String accountName;
        /** Owner name. */
        @AuraEnabled
        public String ownerName;
        /** Current score. */
        @AuraEnabled
        public Integer score;
        /** Current band. */
        @AuraEnabled
        public String status;
        /** Churn probability. */
        @AuraEnabled
        public Integer churnProbability;
        /** ARR. */
        @AuraEnabled
        public Decimal arr;
        /** Contract end date. */
        @AuraEnabled
        public Date contractEndDate;
        /** When the score was last written. */
        @AuraEnabled
        public DateTime lastScored;
        /** Top scoring drivers, biggest impact first. */
        @AuraEnabled
        public List<Driver> drivers = new List<Driver>();
        /** History, oldest first, for the sparkline. */
        @AuraEnabled
        public List<HistoryPoint> history = new List<HistoryPoint>();
        /** True when the viewer may force a recalculation. */
        @AuraEnabled
        public Boolean canRecalculate = false;
        /** True when the viewer may log a signal. */
        @AuraEnabled
        public Boolean canLogSignal = false;
        /** True when the viewer may spend a model call to generate an insight. */
        @AuraEnabled
        public Boolean canGenerateInsight = false;
        /** Written summary, model or rule based. */
        @AuraEnabled
        public String aiSummary;
        /** Recommended next action. */
        @AuraEnabled
        public String nextBestAction;
        /** Risk reasons, one per line in the field, a list here. */
        @AuraEnabled
        public List<String> aiRiskReasons = new List<String>();
        /** AI or Rule-based, so a fallback is never passed off as a model answer. */
        @AuraEnabled
        public String aiSource;
        /** When the summary was generated. */
        @AuraEnabled
        public DateTime aiGeneratedOn;
    }

    /**
     * @param accountId Account to read.
     * @return The card, or a friendly error when the account is not visible.
     */
    @AuraEnabled(cacheable=true)
    public static HealthCard getHealthCard(Id accountId) {
        if (accountId == null) {
            throw userError('No account was supplied.');
        }

        try {
            List<Account> accounts = new RIQ_AccountSelector().getForHealthCards(new Set<Id>{ accountId });

            if (accounts.isEmpty()) {
                throw userError('That account does not exist, or you do not have access to it.');
            }

            Account account = accounts[0];
            List<RIQ_Score_History__c> historyRows = new RIQ_ScoreHistorySelector()
                .getLatestForAccount(accountId, TREND_POINTS);

            HealthCard card = new HealthCard();
            card.accountId = account.Id;
            card.accountName = account.Name;
            card.ownerName = account.Owner.Name;
            card.score = account.RIQ_Health_Score__c == null ? null : account.RIQ_Health_Score__c.intValue();
            card.status = account.RIQ_Health_Status__c;
            card.churnProbability = account.RIQ_Churn_Probability__c == null
                ? null
                : account.RIQ_Churn_Probability__c.intValue();
            card.arr = account.RIQ_ARR__c;
            card.contractEndDate = account.RIQ_Contract_End_Date__c;
            card.lastScored = account.RIQ_Last_Scored__c;
            card.canRecalculate = FeatureManagement.checkPermission('RIQ_Recalculate_Health');
            card.canLogSignal = FeatureManagement.checkPermission('RIQ_Log_Health_Signals');
            card.canGenerateInsight = FeatureManagement.checkPermission('RIQ_Generate_AI_Insight');
            card.aiSummary = account.RIQ_AI_Summary__c;
            card.nextBestAction = account.RIQ_Next_Best_Action__c;
            card.aiSource = account.RIQ_AI_Source__c;
            card.aiGeneratedOn = account.RIQ_AI_Generated_On__c;

            if (String.isNotBlank(account.RIQ_AI_Risk_Reasons__c)) {
                for (String reason : account.RIQ_AI_Risk_Reasons__c.split('\n')) {
                    if (String.isNotBlank(reason)) {
                        card.aiRiskReasons.add(reason.trim());
                    }
                }
            }

            if (!historyRows.isEmpty()) {
                card.drivers = parseDrivers(historyRows[0].Drivers__c);
            }

            card.history = toTrend(historyRows);
            return card;
        } catch (AuraHandledException friendly) {
            throw friendly;
        } catch (Exception failure) {
            throw handleFailure(failure, 'load this account');
        }
    }

    /**
     * @description Forces a recalculation for one account through the same
     * service the trigger and the nightly batch use, then returns the fresh
     * card so the client can render the new number immediately.
     * @param accountId Account to recalculate.
     * @return The updated card.
     */
    @AuraEnabled
    public static HealthCard recalculate(Id accountId) {
        if (accountId == null) {
            throw userError('No account was supplied.');
        }

        if (!FeatureManagement.checkPermission('RIQ_Recalculate_Health')) {
            throw userError('You do not have permission to recalculate health scores.');
        }

        try {
            RIQ_HealthScoreRecalculator.ProcessResult result = RIQ_HealthScoreRecalculator.process(
                new Set<Id>{ accountId }
            );

            if (result.processedCount == 0) {
                throw userError(
                    'That account could not be scored. It may have been deleted, or you may not have access to it.'
                );
            }

            return getHealthCard(accountId);
        } catch (AuraHandledException friendly) {
            throw friendly;
        } catch (Exception failure) {
            throw handleFailure(failure, 'recalculate this account');
        }
    }

    /**
     * @description Logs one health signal. The signal trigger queues the
     * recalculation, which is why the caller must not expect the new score to
     * exist the moment this returns.
     * @param accountId Account to attach the signal to.
     * @param signalType Valid picklist value.
     * @param severity 1..5.
     * @param occurredOn Today or earlier.
     * @param notes Optional context.
     * @return Id of the created signal.
     */
    @AuraEnabled
    public static Id logSignal(Id accountId, String signalType, Integer severity, Date occurredOn, String notes) {
        if (!FeatureManagement.checkPermission('RIQ_Log_Health_Signals')) {
            throw userError('You do not have permission to log health signals.');
        }

        if (accountId == null) {
            throw userError('Choose an account before logging a signal.');
        }

        if (severity == null || severity < MIN_SEVERITY || severity > MAX_SEVERITY) {
            throw userError('Severity must be a whole number between ' + MIN_SEVERITY + ' and ' + MAX_SEVERITY + '.');
        }

        if (occurredOn == null) {
            throw userError('Choose the date the signal happened.');
        }

        if (occurredOn > Date.today()) {
            throw userError('A signal cannot be dated in the future.');
        }

        if (!signalTypes().contains(signalType)) {
            throw userError('"' + signalType + '" is not a known signal type.');
        }

        if (notes != null && notes.length() > MAX_NOTES_LENGTH) {
            throw userError('The notes are too long. Shorten them to ' + MAX_NOTES_LENGTH + ' characters or fewer.');
        }

        try {
            if (new RIQ_AccountSelector().getForHealthCards(new Set<Id>{ accountId }).isEmpty()) {
                throw userError('That account does not exist, or you do not have access to it.');
            }

            RIQ_Health_Signal__c signal = new RIQ_Health_Signal__c(
                Account__c = accountId,
                Signal_Type__c = signalType,
                Severity__c = severity,
                Occurred_On__c = occurredOn,
                Notes__c = notes
            );

            Database.insert(signal, AccessLevel.USER_MODE);
            return signal.Id;
        } catch (AuraHandledException friendly) {
            throw friendly;
        } catch (DmlException dmlFailure) {
            RIQ_Logger.error('RIQ_AccountHealthController', 'Signal insert failed.', dmlFailure, accountId);
            throw userError('The signal could not be saved. Check the values and try again.');
        } catch (Exception failure) {
            throw handleFailure(failure, 'log the signal');
        }
    }

    /**
     * @description Generates the insight for one account and returns the fresh
     * card. The callout happens before any DML in this transaction, so the
     * platform's "callouts must precede DML" rule is respected; the write is a
     * single update afterwards.
     *
     * The generative step is gated by a Custom Permission because every call can
     * cost money at the model provider. Without it, a Read-Only user cannot even
     * reach the code path, whether or not the component hid the button.
     * @param accountId Account to summarise.
     * @return The updated card.
     */
    @AuraEnabled
    public static HealthCard generateInsight(Id accountId) {
        if (accountId == null) {
            throw userError('No account was supplied.');
        }

        if (!FeatureManagement.checkPermission('RIQ_Generate_AI_Insight')) {
            throw userError('You do not have permission to generate AI insights.');
        }

        try {
            List<Account> accounts = new RIQ_AccountSelector().getForAiInsight(new Set<Id>{ accountId });

            if (accounts.isEmpty()) {
                throw userError('That account does not exist, or you do not have access to it.');
            }

            List<RIQ_Score_History__c> historyRows = new RIQ_ScoreHistorySelector().getLatestForAccount(accountId, 1);
            List<RIQ_Health_Signal__c> signals = new RIQ_HealthSignalSelector()
                .getByAccountIds(new Set<Id>{ accountId });

            RIQ_AiInsightService.Insight insight = RIQ_AiInsightService.generate(
                accounts[0],
                signals,
                historyRows.isEmpty() ? null : historyRows[0].Drivers__c
            );

            RIQ_AiInsightService.persist(accountId, insight);
            return getHealthCard(accountId);
        } catch (AuraHandledException friendly) {
            throw friendly;
        } catch (Exception failure) {
            throw handleFailure(failure, 'generate an insight for this account');
        }
    }

    /**
     * @description Picklist values for the signal logger, read from the field
     * describe rather than hardcoded, so a new signal type needs no code change.
     * @return Valid signal type values.
     */
    @AuraEnabled(cacheable=true)
    public static List<String> getSignalTypes() {
        List<String> types = new List<String>(signalTypes());
        types.sort();
        return types;
    }

    /**
     * @description Parses the Drivers__c JSON without ever throwing. A history
     * row written by an older version of the engine, a truncated payload or a
     * hand-edited value must degrade to "no explanation", never to a broken
     * record page.
     * @param driversJson Serialized driver array.
     * @return Up to MAX_DRIVERS drivers; empty when unreadable.
     */
    @TestVisible
    private static List<Driver> parseDrivers(String driversJson) {
        List<Driver> drivers = new List<Driver>();

        if (String.isBlank(driversJson)) {
            return drivers;
        }

        try {
            Object parsed = JSON.deserializeUntyped(driversJson);

            if (!(parsed instanceof List<Object>)) {
                System.debug(LoggingLevel.WARN, 'RenewalIQ: drivers JSON is not an array.'); // NOPMD cacheable read path cannot publish
                return drivers;
            }

            for (Object item : (List<Object>) parsed) {
                if (drivers.size() >= MAX_DRIVERS) {
                    break;
                }

                if (!(item instanceof Map<String, Object>)) {
                    continue;
                }

                Map<String, Object> values = (Map<String, Object>) item;
                Driver driver = new Driver();
                driver.signalType = (String) values.get('signalType');
                driver.severity = toInteger(values.get('severity'));
                driver.points = toDecimal(values.get('points'));
                driver.occurredOn = toDate(values.get('occurredOn'));
                driver.explanation = (String) values.get('explanation');
                drivers.add(driver);
            }
        } catch (Exception parseFailure) {
            System.debug(LoggingLevel.WARN, 'RenewalIQ: unreadable drivers JSON.'); // NOPMD cacheable read path cannot publish
            return new List<Driver>();
        }

        return drivers;
    }

    /**
     * @param historyRows Newest-first history.
     * @return Oldest-first points for the sparkline.
     */
    private static List<HistoryPoint> toTrend(List<RIQ_Score_History__c> historyRows) {
        List<HistoryPoint> trend = new List<HistoryPoint>();

        for (Integer i = historyRows.size() - 1; i >= 0; i--) {
            RIQ_Score_History__c row = historyRows[i];
            HistoryPoint point = new HistoryPoint();
            point.calculatedOn = row.Calculated_On__c;
            point.score = row.Score__c == null ? null : row.Score__c.intValue();
            point.status = row.Status__c;
            trend.add(point);
        }

        return trend;
    }

    /**
     * @param value Raw JSON value.
     * @return Integer or null.
     */
    private static Integer toInteger(Object value) {
        if (value == null) {
            return null;
        }

        try {
            return Integer.valueOf(String.valueOf(value));
        } catch (Exception notANumber) {
            return null;
        }
    }

    /**
     * @param value Raw JSON value.
     * @return Decimal or null.
     */
    private static Decimal toDecimal(Object value) {
        if (value == null) {
            return null;
        }

        try {
            return Decimal.valueOf(String.valueOf(value));
        } catch (Exception notANumber) {
            return null;
        }
    }

    /**
     * @param value Raw JSON value.
     * @return Date or null.
     */
    private static Date toDate(Object value) {
        if (value == null) {
            return null;
        }

        try {
            return Date.valueOf(String.valueOf(value));
        } catch (Exception notADate) {
            return null;
        }
    }

    /**
     * @return The deployed signal type picklist values.
     */
    private static Set<String> signalTypes() {
        Set<String> values = new Set<String>();

        for (Schema.PicklistEntry entry : RIQ_Health_Signal__c.Signal_Type__c.getDescribe().getPicklistValues()) {
            values.add(entry.getValue());
        }

        return values;
    }

    /**
     * @param failure The internal error.
     * @param action What the caller was trying to do.
     * @return A friendly exception carrying a support-safe message.
     */
    private static AuraHandledException handleFailure(Exception failure, String action) {
        // The user gets a friendly sentence; the administrator gets the stack in
        // RIQ_Log__c. Raw exception text never reaches the client.
        RIQ_Logger.error('RIQ_AccountHealthController', 'Could not ' + action + '.', failure);
        return userError(
            'RenewalIQ could not ' + action + '. Please try again, or contact your Salesforce administrator.'
        );
    }

    /**
     * @param message Message shown to the user.
     * @return An AuraHandledException that keeps its message on the client.
     */
    private static AuraHandledException userError(String message) {
        AuraHandledException friendly = new AuraHandledException(message);
        friendly.setMessage(message);
        return friendly;
    }
}
