@IsTest
private class RIQ_AiInsightService_Test {
    private static final String DRIVERS_JSON =
        '[{"signalType":"Support Escalation","severity":4,"points":22,"occurredOn":"2026-11-01",' +
        '"explanation":"Three P1s in thirty days"},' +
        '{"signalType":"Low Product Usage","severity":3,"points":11,"occurredOn":"2026-10-28",' +
        '"explanation":"Active users down"}]';

    /**
     * @return An enabled configuration pointing at the mocked credential.
     */
    private static RIQ_AiInsightService.Config enabledConfig() {
        RIQ_AiInsightService.Config config = new RIQ_AiInsightService.Config();
        config.isEnabled = true;
        config.modelName = 'llama-3.3-70b-versatile';
        config.maxTokens = 400;
        config.timeoutSeconds = 30;
        return config;
    }

    /**
     * @param name Account name.
     * @return Unsaved account with commercial context.
     */
    private static Account account(String name) {
        return new Account(
            Name = name,
            RIQ_ARR__c = 480000,
            RIQ_Contract_End_Date__c = Date.today().addDays(45),
            RIQ_Health_Score__c = 42,
            RIQ_Health_Status__c = 'At Risk'
        );
    }

    @IsTest
    static void promptCarriesContextButNoPersonalData() {
        Account testAccount = account('Prompt Account');

        RIQ_Health_Signal__c withNotes = new RIQ_Health_Signal__c(
            Signal_Type__c = 'Support Escalation',
            Severity__c = 4,
            Occurred_On__c = Date.today().addDays(-3),
            Notes__c = 'Call Jane Doe on +1 555 0100 or jane.doe@example.com - she is furious'
        );

        Test.startTest();
        String prompt = RIQ_AiInsightService.buildPrompt(
            testAccount,
            new List<RIQ_Health_Signal__c>{ withNotes },
            DRIVERS_JSON
        );
        Test.stopTest();

        System.assert(prompt.contains('Score'.toLowerCase()) || prompt.contains('Health score'), 'Score is included.');
        System.assert(prompt.contains('42/100'), 'The score value is included.');
        System.assert(prompt.contains('At Risk'), 'The band is included.');
        System.assert(prompt.contains('Support Escalation | 4'), 'Signal type and severity are included.');
        System.assert(prompt.contains('Top scoring drivers'), 'Drivers are summarised.');
        System.assert(!prompt.contains('Jane'), 'Notes must never reach the model.');
        System.assert(!prompt.contains('555'), 'No phone numbers.');
        System.assert(!prompt.contains('@example.com'), 'No email addresses.');
        System.assert(!prompt.contains('furious'), 'No free-text customer quotes.');
    }

    @IsTest
    static void promptCapsTheNumberOfSignals() {
        List<RIQ_Health_Signal__c> signals = new List<RIQ_Health_Signal__c>();

        for (Integer i = 0; i < 25; i++) {
            signals.add(
                new RIQ_Health_Signal__c(
                    Signal_Type__c = 'Missed QBR',
                    Severity__c = 2,
                    Occurred_On__c = Date.today().addDays(-i)
                )
            );
        }

        Test.startTest();
        String prompt = RIQ_AiInsightService.buildPrompt(account('Bulk Prompt'), signals, null);
        Test.stopTest();

        System.assertEquals(
            RIQ_AiInsightService.MAX_SIGNALS_IN_PROMPT,
            prompt.countMatches('- Missed QBR'),
            'Only the newest signals are sent.'
        );
    }

    @IsTest
    static void successfulCalloutProducesAnAiInsight() {
        RIQ_AiInsightService.configOverride = enabledConfig();
        RIQ_CalloutMocks.Recorder recorder = new RIQ_CalloutMocks.Recorder();
        Test.setMock(HttpCalloutMock.class, recorder);

        Test.startTest();
        RIQ_AiInsightService.Insight insight = RIQ_AiInsightService.generate(
            account('AI Account'),
            new List<RIQ_Health_Signal__c>(),
            DRIVERS_JSON
        );
        Test.stopTest();

        System.assertEquals(RIQ_AiInsightService.SOURCE_AI, insight.source);
        System.assert(insight.generatedByModel);
        System.assertEquals('Usage is down and the sponsor left.', insight.summary);
        System.assertEquals('Book an executive call.', insight.nextBestAction);
        System.assertEquals(2, insight.riskReasons.size());
        System.assertEquals(1, recorder.callCount);
        System.assertEquals(
            'callout:RIQ_LLM_API/openai/v1/chat/completions',
            recorder.lastEndpoint,
            'The callout goes through the named credential to the Groq path.'
        );
        System.assertEquals('application/json', recorder.lastContentType);
        System.assert(!recorder.lastBody.contains('sk-'), 'No key material is in the body.');
        System.assert(
            !recorder.lastBody.containsIgnoreCase('bearer'),
            'The Authorization header is applied by the External Credential, never by Apex.'
        );
    }

    @IsTest
    static void disabledConfigMakesNoCalloutAndUsesRules() {
        RIQ_AiInsightService.Config disabled = new RIQ_AiInsightService.Config();
        disabled.isEnabled = false;
        RIQ_AiInsightService.configOverride = disabled;

        RIQ_CalloutMocks.Recorder recorder = new RIQ_CalloutMocks.Recorder();
        Test.setMock(HttpCalloutMock.class, recorder);

        Test.startTest();
        RIQ_AiInsightService.Insight insight = RIQ_AiInsightService.generate(
            account('Disabled Account'),
            new List<RIQ_Health_Signal__c>(),
            DRIVERS_JSON
        );
        Test.stopTest();

        System.assertEquals(0, recorder.callCount, 'A disabled toggle must not reach the network.');
        System.assertEquals(RIQ_AiInsightService.SOURCE_RULE_BASED, insight.source);
        System.assertEquals(false, insight.generatedByModel);
        System.assert(insight.summary.contains('At Risk'), 'The rule-based summary names the band.');
        System.assertEquals('Support Escalation (-22 pts)', insight.riskReasons[0]);
    }

    @IsTest
    static void everyBadStatusFallsBackToRules() {
        RIQ_AiInsightService.configOverride = enabledConfig();
        List<Integer> statuses = new List<Integer>{ 400, 401, 403, 429, 500, 503 };

        Test.startTest();

        for (Integer status : statuses) {
            Test.setMock(HttpCalloutMock.class, new RIQ_CalloutMocks.Responder(status, '{"error":"nope"}'));
            RIQ_AiInsightService.Insight insight = RIQ_AiInsightService.generate(
                account('Status ' + status),
                new List<RIQ_Health_Signal__c>(),
                null
            );
            System.assertEquals(
                RIQ_AiInsightService.SOURCE_RULE_BASED,
                insight.source,
                'HTTP ' + status + ' must degrade to the rule-based insight.'
            );
            System.assert(String.isNotBlank(insight.nextBestAction));
        }

        Test.stopTest();
    }

    @IsTest
    static void timeoutFallsBackToRules() {
        RIQ_AiInsightService.configOverride = enabledConfig();
        Test.setMock(HttpCalloutMock.class, new RIQ_CalloutMocks.Timeout());

        Test.startTest();
        RIQ_AiInsightService.Insight insight = RIQ_AiInsightService.generate(
            account('Timeout Account'),
            new List<RIQ_Health_Signal__c>(),
            null
        );
        Test.stopTest();

        System.assertEquals(RIQ_AiInsightService.SOURCE_RULE_BASED, insight.source);
        System.assert(String.isNotBlank(insight.summary));
    }

    @IsTest
    static void malformedBodiesFallBackToRules() {
        RIQ_AiInsightService.configOverride = enabledConfig();
        List<String> bodies = new List<String>{
            '',
            RIQ_CalloutMocks.EMPTY_CHOICES_BODY,
            RIQ_CalloutMocks.PROSE_BODY,
            '{"choices":[{"message":null}]}'
        };

        for (String content : new List<String>{
            'not json at all',
            '{"summary":null}',
            '{"nextBestAction":"only an action"}',
            '   '
        }) {
            bodies.add('{"choices":[{"index":0,"message":{"role":"assistant","content":' + JSON.serialize(content) + '}}]}');
        }

        Test.startTest();

        for (String body : bodies) {
            Test.setMock(HttpCalloutMock.class, new RIQ_CalloutMocks.Responder(200, body));
            RIQ_AiInsightService.Insight insight = RIQ_AiInsightService.generate(
                account('Malformed'),
                new List<RIQ_Health_Signal__c>(),
                null
            );
            System.assertEquals(RIQ_AiInsightService.SOURCE_RULE_BASED, insight.source, 'Body should be rejected: ' + body);
        }

        Test.stopTest();
    }

    @IsTest
    static void fencedAndGroqResponsesAreParsed() {
        RIQ_AiInsightService.Insight fenced = RIQ_AiInsightService.parseResponse(RIQ_CalloutMocks.FENCED_BODY);
        System.assertEquals('Fenced summary.', fenced.summary);
        System.assertEquals('Fenced reason', fenced.riskReasons[0]);

        RIQ_AiInsightService.Insight groq = RIQ_AiInsightService.parseResponse(RIQ_CalloutMocks.GROQ_SUCCESS_BODY);
        System.assertEquals('Usage is down and the sponsor left.', groq.summary);
        System.assertEquals('Book an executive call.', groq.nextBestAction);
        System.assertEquals(RIQ_AiInsightService.SOURCE_AI, groq.source);

        System.assertEquals(null, RIQ_AiInsightService.parseResponse(null));
        System.assertEquals(null, RIQ_AiInsightService.parseResponse(RIQ_CalloutMocks.EMPTY_CHOICES_BODY));
    }

    @IsTest
    static void longAnswersAreTruncatedToFieldLimits() {
        String longSummary = 'x'.repeat(9000);
        String longAction = 'y'.repeat(900);
        String longReason = 'z'.repeat(900);
        String body =
            '{"choices":[{"index":0,"message":{"role":"assistant","content":' +
            JSON.serialize(
                '{"summary":"' + longSummary + '","nextBestAction":"' + longAction +
                '","riskReasons":["' + longReason + '","b","c","d"]}'
            ) +
            '}}]}';

        RIQ_AiInsightService.Insight insight = RIQ_AiInsightService.parseResponse(body);

        System.assertEquals(RIQ_AiInsightService.MAX_SUMMARY_CHARS, insight.summary.length());
        System.assertEquals(RIQ_AiInsightService.MAX_ACTION_CHARS, insight.nextBestAction.length());
        System.assertEquals(RIQ_AiInsightService.MAX_REASONS, insight.riskReasons.size(), 'Reasons are capped at three.');
        System.assertEquals(RIQ_AiInsightService.MAX_REASON_CHARS, insight.riskReasons[0].length());
    }

    @IsTest
    static void driverLabelsSurviveGarbage() {
        System.assertEquals(0, RIQ_AiInsightService.topDriverLabels(null, 3).size());
        System.assertEquals(0, RIQ_AiInsightService.topDriverLabels('{not an array}', 3).size());
        System.assertEquals(0, RIQ_AiInsightService.topDriverLabels('["just a string"]', 3).size());
        System.assertEquals(1, RIQ_AiInsightService.topDriverLabels(DRIVERS_JSON, 1).size());
        System.assertEquals('Low Product Usage (-11 pts)', RIQ_AiInsightService.topDriverLabels(DRIVERS_JSON, 2)[1]);
    }

    @IsTest
    static void ruleBasedInsightHandlesAnEmptyAccount() {
        Account blank = new Account(Name = 'Blank Account');

        Test.startTest();
        RIQ_AiInsightService.Insight insight = RIQ_AiInsightService.buildRuleBased(blank, null, null);
        RIQ_AiInsightService.Insight noAccount = RIQ_AiInsightService.generate(null, null, null);
        Test.stopTest();

        System.assertEquals('Unscored', insight.summary.substringBefore(' account'));
        System.assertEquals(1, insight.riskReasons.size(), 'A fallback reason is always supplied.');
        System.assert(String.isNotBlank(noAccount.summary));
    }

    @IsTest
    static void persistWritesTheInsightOntoTheAccount() {
        Account testAccount = new Account(Name = 'Persist Account');
        insert testAccount;

        RIQ_AiInsightService.Insight insight = new RIQ_AiInsightService.Insight();
        insight.summary = 'Summary text.';
        insight.nextBestAction = 'Do the thing.';
        insight.riskReasons = new List<String>{ 'One', 'Two' };
        insight.source = RIQ_AiInsightService.SOURCE_AI;
        insight.generatedOn = DateTime.now();

        Test.startTest();
        RIQ_AiInsightService.persist(testAccount.Id, insight);
        RIQ_AiInsightService.persist(null, insight);
        RIQ_AiInsightService.persist(testAccount.Id, null);
        Test.stopTest();

        Account stored = [
            SELECT RIQ_AI_Summary__c, RIQ_Next_Best_Action__c, RIQ_AI_Risk_Reasons__c, RIQ_AI_Source__c, RIQ_AI_Generated_On__c
            FROM Account
            WHERE Id = :testAccount.Id
        ];

        System.assertEquals('Summary text.', stored.RIQ_AI_Summary__c);
        System.assertEquals('Do the thing.', stored.RIQ_Next_Best_Action__c);
        System.assertEquals('One\nTwo', stored.RIQ_AI_Risk_Reasons__c);
        System.assertEquals(RIQ_AiInsightService.SOURCE_AI, stored.RIQ_AI_Source__c);
        System.assertNotEquals(null, stored.RIQ_AI_Generated_On__c);
    }

    @IsTest
    static void configComesFromCustomMetadataByDefault() {
        Test.startTest();
        RIQ_AiInsightService.Config config = RIQ_AiInsightService.loadConfig();
        Test.stopTest();

        System.assertNotEquals(null, config);
        System.assertEquals(false, config.isEnabled, 'The shipped default is disabled, so no key is required.');
        System.assert(String.isNotBlank(config.modelName));
        System.assert(config.endpoint.startsWith('callout:'));
        System.assertEquals('Groq', config.provider);
        System.assertEquals('/openai/v1/chat/completions', config.requestPath);
        System.assertEquals(
            'callout:RIQ_LLM_API/openai/v1/chat/completions',
            config.endpoint,
            'The endpoint is the named credential plus the configured path.'
        );
    }

    @IsTest
    static void requestPathNormalizationSurvivesSloppyInput() {
        System.assertEquals('/v1/chat/completions', RIQ_AiInsightService.normalizePath('v1/chat/completions'));
        System.assertEquals('/v1/chat/completions', RIQ_AiInsightService.normalizePath('  /v1/chat/completions  '));
        System.assertEquals(
            '/openai/v1/chat/completions',
            RIQ_AiInsightService.normalizePath('   '),
            'A blank path falls back to the Groq default instead of a broken endpoint.'
        );
    }

    @IsTest
    static void requestBodyIsAnOpenAiStyleChatCompletion() {
        String body = RIQ_AiInsightService.buildRequestBody(enabledConfig(), 'Hello prompt');
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(body);

        System.assertEquals('llama-3.3-70b-versatile', parsed.get('model'));
        System.assertEquals(400, ((Decimal) parsed.get('max_tokens')).intValue());
        System.assertEquals(0.2, ((Decimal) parsed.get('temperature')).doubleValue(), 'Low temperature keeps the prose repeatable.');
        System.assertEquals('json_object', ((Map<String, Object>) parsed.get('response_format')).get('type'));

        List<Object> messages = (List<Object>) parsed.get('messages');
        System.assertEquals(2, messages.size());
        System.assertEquals('system', ((Map<String, Object>) messages[0]).get('role'));
        System.assertEquals('user', ((Map<String, Object>) messages[1]).get('role'));
        System.assertEquals('Hello prompt', ((Map<String, Object>) messages[1]).get('content'));
    }

    @IsTest
    static void requestBodyCarriesNoFreeTextOrPersonalData() {
        RIQ_AiInsightService.configOverride = enabledConfig();
        RIQ_CalloutMocks.Recorder recorder = new RIQ_CalloutMocks.Recorder();
        Test.setMock(HttpCalloutMock.class, recorder);

        RIQ_Health_Signal__c withNotes = new RIQ_Health_Signal__c(
            Signal_Type__c = 'Support Escalation',
            Severity__c = 4,
            Occurred_On__c = Date.today().addDays(-2),
            Notes__c = 'Call Jane Doe on +1 555 0100 or jane.doe@example.com'
        );

        Test.startTest();
        RIQ_AiInsightService.generate(account('Groq Body Account'), new List<RIQ_Health_Signal__c>{ withNotes }, DRIVERS_JSON);
        Test.stopTest();

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(recorder.lastBody);
        System.assertEquals('llama-3.3-70b-versatile', body.get('model'));
        System.assertNotEquals(null, body.get('response_format'), 'JSON mode is requested, so the reply is parseable by contract.');
        System.assertEquals(2, ((List<Object>) body.get('messages')).size());
        System.assert(!recorder.lastBody.contains('Jane'), 'Notes must never reach the model.');
        System.assert(!recorder.lastBody.contains('555'), 'No phone numbers.');
        System.assert(!recorder.lastBody.contains('@example.com'), 'No email addresses.');
    }

    @IsTest
    static void rateLimitFallsBackWithoutRetryingInProcess() {
        RIQ_AiInsightService.configOverride = enabledConfig();
        RIQ_CalloutMocks.Responder throttled = new RIQ_CalloutMocks.Responder(
            429,
            '{"error":{"message":"Rate limit reached"}}',
            '12'
        );
        Test.setMock(HttpCalloutMock.class, throttled);

        Test.startTest();
        RIQ_AiInsightService.Insight insight = RIQ_AiInsightService.generate(
            account('Throttled'),
            new List<RIQ_Health_Signal__c>(),
            DRIVERS_JSON
        );
        Test.stopTest();

        System.assertEquals(RIQ_AiInsightService.SOURCE_RULE_BASED, insight.source);
        System.assertEquals(1, throttled.callCount, 'Retry-After is read, never waited on: one request, one fallback.');
        System.assertEquals('Support Escalation (-22 pts)', insight.riskReasons[0], 'The fallback still explains the account.');
    }
}
