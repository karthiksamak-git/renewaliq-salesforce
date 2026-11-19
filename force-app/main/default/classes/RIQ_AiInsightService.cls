/**
 * @description Turns an account's health data into a written insight: a
 * summary, a next best action and up to three risk reasons. The provider is
 * Groq's OpenAI-compatible chat completions API, reached through the
 * RIQ_LLM_API External Credential so no key exists in Apex.
 *
 * Three rules shape this class:
 *
 * 1. It never throws. A missing key, a disabled toggle, a timeout, a 429 or a
 *    malformed body all degrade to a deterministic rule-based insight, because
 *    the record page must still explain the account.
 * 2. It holds no DML. Persisting the result is the caller's job (the controller
 *    or the queueable), which is what keeps the callout free of uncommitted work.
 * 3. The prompt carries no free text and no personal data: signal types,
 *    severities, dates, the score and the commercial context only. Notes are
 *    deliberately excluded - they are written by humans about humans.
 */
public with sharing class RIQ_AiInsightService {
    /** Source value for a model response. */
    public static final String SOURCE_AI = 'AI';
    /** Source value for the deterministic fallback. */
    public static final String SOURCE_RULE_BASED = 'Rule-based';

    /** Named Credential created by this project's metadata. */
    private static final String NAMED_CREDENTIAL = 'callout:RIQ_LLM_API';
    /** Groq's OpenAI-compatible chat completions path; overridable in metadata. */
    private static final String DEFAULT_REQUEST_PATH = '/openai/v1/chat/completions';
    /** Fixed instruction; the account data travels in the user message. */
    private static final String SYSTEM_PROMPT =
        'You are a customer success analyst writing a short internal note about one account. ' +
        'Answer with JSON only: {"summary": "<=600 characters", "nextBestAction": "<=200 characters", ' +
        '"riskReasons": ["<=3 short reasons"]}. Never include names, email addresses, phone numbers or ' +
        'verbatim customer quotes.';
    /** DeveloperName of the single configuration record. */
    private static final String CONFIG_DEVELOPER_NAME = 'Default';

    /** Signals sent to the model. Ten is enough context and keeps the prompt cheap. */
    public static final Integer MAX_SIGNALS_IN_PROMPT = 10;
    /** Long text field budget, well under the 131072 limit. */
    public static final Integer MAX_SUMMARY_CHARS = 3000;
    /** Text(255) budget for the next best action. */
    public static final Integer MAX_ACTION_CHARS = 255;
    /** Risk reasons kept from a response. */
    public static final Integer MAX_REASONS = 3;
    /** Per-reason budget for the long text field. */
    public static final Integer MAX_REASON_CHARS = 180;

    private static final Integer MIN_TIMEOUT_MS = 5000;
    private static final Integer MAX_TIMEOUT_MS = 120000;

    /** Runtime configuration, read from Custom Metadata so it is deployable. */
    public class Config {
        /** Master switch: false means no callout at all. */
        public Boolean isEnabled = false;
        /** Model identifier sent in the body. */
        public String modelName = 'openai/gpt-oss-120b';
        /** Which OpenAI-compatible provider this targets; operator documentation. */
        public String provider = 'Groq';
        /** Path appended to the Named Credential URL. */
        public String requestPath = DEFAULT_REQUEST_PATH;
        /** Response token budget. */
        public Integer maxTokens = 400;
        /** Callout timeout in seconds. */
        public Integer timeoutSeconds = 30;
        /** Fully resolved endpoint, including the named credential prefix. */
        public String endpoint = NAMED_CREDENTIAL + DEFAULT_REQUEST_PATH;
    }

    /** The insight the UI renders. */
    public class Insight {
        /** Narrative summary. */
        public String summary;
        /** One recommended action. */
        public String nextBestAction;
        /** Up to three short reasons. */
        public List<String> riskReasons = new List<String>();
        /** SOURCE_AI or SOURCE_RULE_BASED. */
        public String source = SOURCE_RULE_BASED;
        /** When this insight was produced. */
        public DateTime generatedOn;
        /** True when the model was asked and answered successfully. */
        public Boolean generatedByModel = false;
    }

    /** One HTTP attempt, kept separate so tests can inspect it. */
    public class CalloutResult {
        /** True only for a 200 with a body. */
        public Boolean ok = false;
        /** HTTP status; 0 when the callout never completed. */
        public Integer statusCode = 0;
        /** Raw response body. */
        public String body;
    }

    /** Test seam: when set, loadConfig() returns this instead of the metadata. */
    @TestVisible
    private static Config configOverride;

    /**
     * @description Reads the single RIQ_AI_Config__mdt record. A missing record
     * or a missing field falls back to the safe defaults, so metadata being
     * absent disables the feature instead of breaking the page.
     * @return Runtime configuration.
     */
    public static Config loadConfig() {
        if (configOverride != null) {
            return configOverride;
        }

        Config config = new Config();
        // Custom metadata has no FLS or sharing, so a CRUD check here is a no-op.
        // The suppression is inline because PMD only honours NOPMD on the line it
        // reports, and the Apex formatter would move a bracket comment onto its own
        // line - which is exactly why this statement is skipped by prettier.
        // prettier-ignore
        List<RIQ_AI_Config__mdt> records = [ // NOPMD custom metadata has no FLS or sharing
            SELECT Is_Enabled__c, Model_Name__c, Max_Tokens__c, Timeout_Seconds__c, Provider__c, Request_Path__c
            FROM RIQ_AI_Config__mdt
            WHERE DeveloperName = :CONFIG_DEVELOPER_NAME
            LIMIT 1
        ];

        if (records.isEmpty()) {
            return config;
        }

        RIQ_AI_Config__mdt record = records[0];
        config.isEnabled = record.Is_Enabled__c == true;
        config.modelName = String.isBlank(record.Model_Name__c) ? config.modelName : record.Model_Name__c;
        config.maxTokens = record.Max_Tokens__c == null ? config.maxTokens : record.Max_Tokens__c.intValue();
        config.timeoutSeconds = record.Timeout_Seconds__c == null
            ? config.timeoutSeconds
            : record.Timeout_Seconds__c.intValue();
        config.provider = String.isBlank(record.Provider__c) ? config.provider : record.Provider__c;
        config.requestPath = String.isBlank(record.Request_Path__c)
            ? config.requestPath
            : normalizePath(record.Request_Path__c);
        config.endpoint = NAMED_CREDENTIAL + config.requestPath;
        return config;
    }

    /**
     * @description Keeps the path usable whether or not the admin typed a leading
     * slash, because an endpoint is not the place to be pedantic about input.
     * @param path Configured path.
     * @return Path beginning with a slash.
     */
    public static String normalizePath(String path) {
        String trimmed = path == null ? '' : path.trim();

        if (String.isBlank(trimmed)) {
            return DEFAULT_REQUEST_PATH;
        }

        return trimmed.startsWith('/') ? trimmed : '/' + trimmed;
    }

    /**
     * @description Produces an insight for one account: the model when it is
     * enabled and answers, the rules otherwise. Never throws.
     * @param account Account with score, status, ARR and contract end loaded.
     * @param signals Signals for that account, newest first; may be null.
     * @param driversJson The newest Drivers__c payload, already read by the caller.
     * @return An insight, always populated.
     */
    public static Insight generate(Account account, List<RIQ_Health_Signal__c> signals, String driversJson) {
        List<RIQ_Health_Signal__c> safeSignals = signals == null ? new List<RIQ_Health_Signal__c>() : signals;
        Config config = loadConfig();
        Insight insight;

        if (account == null) {
            insight = new Insight();
            insight.summary = 'No account data was available to summarise.';
            insight.nextBestAction = 'Refresh the account and try again.';
            insight.generatedOn = DateTime.now();
            return insight;
        }

        if (config.isEnabled) {
            try {
                String body = buildRequestBody(config, buildPrompt(account, safeSignals, driversJson));
                CalloutResult result = post(config, body);

                if (result.ok) {
                    insight = parseResponse(result.body);
                }
            } catch (Exception unexpected) {
                // A defect in prompt building or parsing must not cost the user
                // their page: fall through to the rule-based insight.
                RIQ_Logger.error(
                    'RIQ_AiInsightService',
                    'Insight generation failed, using the rule-based fallback.',
                    unexpected
                );
            }
        }

        if (insight == null) {
            insight = buildRuleBased(account, safeSignals, driversJson);
        }

        insight.generatedOn = DateTime.now();
        return insight;
    }

    /**
     * @description The prompt. Deliberately small and free of personal data:
     * signal types, severities and dates, plus the commercial context.
     * @param account Account to describe.
     * @param signals Signals, newest first.
     * @param driversJson Newest drivers payload, for the top-scoring labels.
     * @return Prompt text.
     */
    public static String buildPrompt(Account account, List<RIQ_Health_Signal__c> signals, String driversJson) {
        List<String> lines = new List<String>();
        lines.add('You are a customer success analyst writing a short internal note about one account.');
        lines.add('');
        lines.add('Account: ' + account.Name);
        lines.add(
            'Health score: ' +
                (account.RIQ_Health_Score__c == null
                    ? 'not scored'
                    : String.valueOf(account.RIQ_Health_Score__c.intValue()) + '/100') +
                ' (' +
                (String.isBlank(account.RIQ_Health_Status__c) ? 'Unknown' : account.RIQ_Health_Status__c) +
                ')'
        );

        if (account.RIQ_ARR__c != null) {
            lines.add('ARR (INR): ' + account.RIQ_ARR__c.intValue());
        }

        if (account.RIQ_Contract_End_Date__c != null) {
            lines.add(
                'Contract ends: ' +
                    String.valueOf(account.RIQ_Contract_End_Date__c) +
                    ' (' +
                    account.RIQ_Contract_End_Date__c.daysBetween(Date.today()) +
                    ' days away)'
            );
        }

        Integer sent = 0;
        if (signals != null && !signals.isEmpty()) {
            lines.add('Recent signals (type | severity 1-5 | date):');

            for (RIQ_Health_Signal__c signal : signals) {
                if (sent >= MAX_SIGNALS_IN_PROMPT) {
                    break;
                }

                lines.add(
                    '- ' +
                        signal.Signal_Type__c +
                        ' | ' +
                        signal.Severity__c +
                        ' | ' +
                        String.valueOf(signal.Occurred_On__c)
                );
                sent++;
            }
        }

        List<String> drivers = topDriverLabels(driversJson, MAX_REASONS);
        if (!drivers.isEmpty()) {
            lines.add('Top scoring drivers: ' + String.join(drivers, ', '));
        }

        lines.add('');
        lines.add(
            'The reader is in India. All amounts are in Indian Rupees (INR). Write large amounts in ' +
            'lakh and crore style, for example 12.5 L or 4.25 Cr, and never use a dollar sign.'
        );
        lines.add('Reply with JSON only, no prose and no code fences:');
        lines.add(
            '{"summary": "<=600 characters", "nextBestAction": "<=200 characters", "riskReasons": ["<=3 short reasons"]}'
        );
        lines.add('Never include names, email addresses, phone numbers or verbatim customer quotes.');
        return String.join(lines, '\n');
    }

    /**
     * @description The OpenAI-compatible chat completion body Groq expects: a
     * system instruction, the account data as the user message, a low temperature
     * for repeatable prose, and JSON mode so the answer is parseable by contract
     * rather than by hope.
     * @param config Resolved configuration.
     * @param prompt Prompt text.
     * @return JSON request body.
     */
    public static String buildRequestBody(Config config, String prompt) {
        Map<String, Object> systemMessage = new Map<String, Object>{ 'role' => 'system', 'content' => SYSTEM_PROMPT };
        Map<String, Object> userMessage = new Map<String, Object>{ 'role' => 'user', 'content' => prompt };
        Map<String, Object> responseFormat = new Map<String, Object>{ 'type' => 'json_object' };
        Map<String, Object> payload = new Map<String, Object>{
            'model' => config.modelName,
            'messages' => new List<Object>{ systemMessage, userMessage },
            'temperature' => 0.2,
            'max_tokens' => config.maxTokens,
            'response_format' => responseFormat
        };
        return JSON.serialize(payload);
    }

    /**
     * @description One callout attempt. Catches CalloutException (including the
     * timeout) and every non-200 status, logging a safe message and returning
     * ok = false so the caller can fall back.
     * @param config Configuration supplying the timeout.
     * @param body Request body.
     * @return The attempt.
     */
    @TestVisible
    private static CalloutResult post(Config config, String body) {
        CalloutResult result = new CalloutResult();
        Integer timeoutMs = Math.min(MAX_TIMEOUT_MS, Math.max(MIN_TIMEOUT_MS, config.timeoutSeconds * 1000));

        HttpRequest request = new HttpRequest();
        request.setEndpoint(config.endpoint);
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setTimeout(timeoutMs);
        request.setBody(body);

        try {
            HttpResponse response = new Http().send(request);
            result.statusCode = response.getStatusCode();
            result.body = response.getBody();
            result.ok = result.statusCode == 200 && String.isNotBlank(result.body);

            if (!result.ok) {
                // Nothing is retried or slept on here on purpose: a synchronous
                // record-page action must return, and the next signal or nightly
                // run regenerates the insight. A Retry-After value is read only so
                // the log tells an operator how hard they are being throttled.
                String retryAfter = retryAfterHeader(response);
                RIQ_Logger.warn(
                    'RIQ_AiInsightService',
                    'Model responded ' +
                        result.statusCode +
                        (retryAfter == null ? '' : ' (Retry-After: ' + retryAfter + 's)') +
                        ', using the rule-based fallback.'
                );
            }
        } catch (CalloutException calloutFailure) {
            // A missing key, a wrong endpoint or a timeout all land here. The
            // message is safe to store: it names the endpoint, never the key.
            RIQ_Logger.warn(
                'RIQ_AiInsightService',
                'The model callout failed, using the rule-based fallback.',
                calloutFailure
            );
        }

        return result;
    }

    /**
     * @description Reads Retry-After without acting on it. Sleeping inside a
     * callout would burn the transaction's CPU and still fail the page, so the
     * only thing done with the value is report it.
     * @param response The throttled response, when there is one.
     * @return Seconds to wait, or null.
     */
    private static String retryAfterHeader(HttpResponse response) {
        String value = response == null ? null : response.getHeader('Retry-After');
        return String.isBlank(value) ? null : value.trim();
    }

    /**
     * @description Parses a model response defensively. Handles the
     * OpenAI-compatible choices shape Groq returns, JSON wrapped in a Markdown
     * code fence, and a body that is not JSON at all.
     * @param body Raw response body.
     * @return Insight, or null when nothing usable was returned.
     */
    public static Insight parseResponse(String body) {
        String content = extractContent(body);

        if (String.isBlank(content)) {
            return null;
        }

        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(unwrapJson(content));
        } catch (Exception notJson) {
            RIQ_Logger.warn(
                'RIQ_AiInsightService',
                'Model response content was not JSON, using the rule-based fallback.'
            );
            return null;
        }

        if (!(parsed instanceof Map<String, Object>)) {
            return null;
        }

        Map<String, Object> values = (Map<String, Object>) parsed;
        String summary = truncate(asString(values.get('summary')), MAX_SUMMARY_CHARS);

        if (String.isBlank(summary)) {
            // Without a summary there is nothing worth showing; the caller falls back.
            return null;
        }

        Insight insight = new Insight();
        insight.summary = summary;
        insight.nextBestAction = truncate(asString(values.get('nextBestAction')), MAX_ACTION_CHARS);
        insight.riskReasons = toReasons(values.get('riskReasons'));
        insight.source = SOURCE_AI;
        insight.generatedByModel = true;
        return insight;
    }

    /**
     * @description Reads choices[0].message.content, the only response shape an
     * OpenAI-compatible chat completions endpoint returns and the only one this
     * service targets. There is deliberately no second code path: an untested
     * compatibility branch is dead code that rots quietly.
     * @param body Response body.
     * @return The text the model produced, or null.
     */
    private static String extractContent(String body) {
        if (String.isBlank(body)) {
            return null;
        }

        try {
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(body);

            if (root.get('choices') instanceof List<Object>) {
                List<Object> choices = (List<Object>) root.get('choices');

                if (!choices.isEmpty() && choices[0] instanceof Map<String, Object>) {
                    Object message = ((Map<String, Object>) choices[0]).get('message');

                    if (message instanceof Map<String, Object>) {
                        return asString(((Map<String, Object>) message).get('content'));
                    }
                }
            }
        } catch (Exception unreadable) {
            RIQ_Logger.warn('RIQ_AiInsightService', 'Model response envelope was not JSON.');
        }

        return null;
    }

    /**
     * @description The rule-based insight: what the app shows when the model is
     * off, unavailable or unhelpful. Built from the same drivers the score uses,
     * so it can never contradict the number.
     * @param account Account to describe.
     * @param signals Signals for that account.
     * @param driversJson Newest drivers payload.
     * @return Insight with source Rule-based.
     */
    public static Insight buildRuleBased(Account account, List<RIQ_Health_Signal__c> signals, String driversJson) {
        Insight insight = new Insight();
        insight.source = SOURCE_RULE_BASED;

        String status = String.isBlank(account.RIQ_Health_Status__c) ? 'Unscored' : account.RIQ_Health_Status__c;
        Integer score = account.RIQ_Health_Score__c == null ? null : account.RIQ_Health_Score__c.intValue();
        Integer signalCount = signals == null ? 0 : signals.size();

        insight.summary =
            status +
            ' account' +
            (score == null ? '' : ' at ' + score + '/100') +
            ' with ' +
            signalCount +
            ' recorded signal' +
            (signalCount == 1 ? '' : 's') +
            ' in the scoring window. ' +
            (account.RIQ_ARR__c == null
                ? ''
                : 'Annual recurring revenue is ' + RIQ_CurrencyFormatter.formatInrCompact(account.RIQ_ARR__c) + '. ') +
            (account.RIQ_Contract_End_Date__c == null
                ? 'No contract end date is on file.'
                : 'The contract ends on ' + String.valueOf(account.RIQ_Contract_End_Date__c) + '.');

        insight.nextBestAction = defaultAction(status);

        List<String> drivers = topDriverLabels(driversJson, MAX_REASONS);

        if (drivers.isEmpty()) {
            drivers.add(
                status == 'Healthy' ? 'No material risk drivers are active.' : 'Too few signals to identify a driver.'
            );
        }

        insight.riskReasons = drivers;
        return insight;
    }

    /**
     * @param status Health band.
     * @return The standard next action for that band.
     */
    private static String defaultAction(String status) {
        if (status == 'Critical') {
            return 'Book an executive call this week and confirm who owns the renewal.';
        }

        if (status == 'At Risk') {
            return 'Schedule a health review and agree a written recovery plan with the sponsor.';
        }

        if (status == 'Watch') {
            return 'Check in with the champion and confirm the next review date.';
        }

        return 'Keep the current cadence and look for expansion at the next review.';
    }

    /**
     * @description Reads the signal types out of a Drivers__c payload. Only the
     * label and the points are used, never an explanation, because explanations
     * are free text and free text is where personal data hides.
     * @param driversJson Serialized drivers array.
     * @param max Maximum labels.
     * @return Labels such as "Support Escalation (-22 pts)".
     */
    public static List<String> topDriverLabels(String driversJson, Integer max) {
        List<String> labels = new List<String>();

        if (String.isBlank(driversJson)) {
            return labels;
        }

        try {
            Object parsed = JSON.deserializeUntyped(driversJson);

            if (!(parsed instanceof List<Object>)) {
                return labels;
            }

            for (Object item : (List<Object>) parsed) {
                if (labels.size() >= max) {
                    break;
                }

                if (!(item instanceof Map<String, Object>)) {
                    continue;
                }

                Map<String, Object> values = (Map<String, Object>) item;
                String label = asString(values.get('signalType'));

                if (String.isBlank(label)) {
                    continue;
                }

                Decimal points = values.get('points') == null
                    ? null
                    : Decimal.valueOf(String.valueOf(values.get('points')));

                if (points != null) {
                    label += ' (' + (points > 0 ? '-' : '+') + Math.abs(points.intValue()) + ' pts)';
                }

                labels.add(truncate(label, MAX_REASON_CHARS));
            }
        } catch (Exception unreadable) {
            // A hand-edited payload degrades to "no drivers", never to an error.
            RIQ_Logger.warn('RIQ_AiInsightService', 'Unreadable drivers JSON, continuing without drivers.');
            return new List<String>();
        }

        return labels;
    }

    /**
     * @description Writes the insight onto the account. Called after the callout,
     * never before it.
     * @param accountId Account to update.
     * @param insight Insight to store.
     */
    public static void persist(Id accountId, Insight insight) {
        if (accountId == null || insight == null) {
            return;
        }

        Account toUpdate = new Account(
            Id = accountId,
            RIQ_AI_Summary__c = truncate(insight.summary, MAX_SUMMARY_CHARS),
            RIQ_Next_Best_Action__c = truncate(insight.nextBestAction, MAX_ACTION_CHARS),
            RIQ_AI_Risk_Reasons__c = String.join(insight.riskReasons, '\n'),
            RIQ_AI_Source__c = insight.source,
            RIQ_AI_Generated_On__c = insight.generatedOn == null ? DateTime.now() : insight.generatedOn
        );

        Database.update(toUpdate, AccessLevel.USER_MODE);
    }

    /**
     * @param body Model output, possibly wrapped in a Markdown code fence.
     * @return The JSON substring.
     */
    private static String unwrapJson(String body) {
        String trimmed = body == null ? '' : body.trim();

        if (trimmed.startsWithIgnoreCase('```')) {
            Integer firstNewline = trimmed.indexOf('\n');
            trimmed = firstNewline == -1 ? '' : trimmed.substring(firstNewline + 1);

            if (trimmed.endsWith('```')) {
                trimmed = trimmed.substring(0, trimmed.length() - 3);
            }
        }

        Integer startIndex = trimmed.indexOf('{');
        Integer endIndex = trimmed.lastIndexOf('}');

        if (startIndex == -1 || endIndex == -1 || endIndex < startIndex) {
            return trimmed;
        }

        return trimmed.substring(startIndex, endIndex + 1);
    }

    /**
     * @param value Raw riskReasons value.
     * @return Clean, capped reasons.
     */
    private static List<String> toReasons(Object value) {
        List<String> reasons = new List<String>();

        if (!(value instanceof List<Object>)) {
            return reasons;
        }

        for (Object entry : (List<Object>) value) {
            if (reasons.size() >= MAX_REASONS) {
                break;
            }

            String reason = truncate(asString(entry), MAX_REASON_CHARS);

            if (String.isNotBlank(reason)) {
                reasons.add(reason);
            }
        }

        return reasons;
    }

    /**
     * @param value Raw value.
     * @return String form, or null.
     */
    private static String asString(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    /**
     * @param value Text.
     * @param max Maximum length.
     * @return Text no longer than max; null stays null.
     */
    private static String truncate(String value, Integer max) {
        if (value == null || value.length() <= max) {
            return value;
        }

        return value.substring(0, max);
    }
}
