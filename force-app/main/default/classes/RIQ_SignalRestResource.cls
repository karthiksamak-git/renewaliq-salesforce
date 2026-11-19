/**
 * @description Inbound signal API: POST /services/apexrest/riq/v1/signals
 *
 * Contract decisions, all documented in docs/API.md:
 *
 * - The body is a JSON array of up to 200 signals; each item carries an
 *   externalId that is the idempotency key, upserted onto
 *   RIQ_Health_Signal__c.RIQ_External_Key__c (unique). A retry updates instead of
 *   duplicating.
 * - Partial success is reported as HTTP 200 with a per-record result array.
 *   Apex REST cannot return 207, and inventing a body-level error for "some
 *   rows worked" would make retries overwrite good records. 400 is reserved for
 *   a body that cannot be read at all, 413 for more than 200 items.
 * - Everything runs in USER_MODE through the selectors and the DML, so the
 *   integration user needs real object and field permissions - see the
 *   RIQ_Integration_User permission set.
 * - No SOQL or DML inside a loop: one account query, one upsert.
 */
@RestResource(urlMapping='/riq/v1/signals/*')
global with sharing class RIQ_SignalRestResource {
    /** Maximum signals accepted in one request. */
    public static final Integer MAX_SIGNALS = 200;
    /** Maximum length of the free-text note stored on the signal. */
    public static final Integer MAX_NOTES_LENGTH = 5000;
    /** Lowest and highest severity accepted. */
    private static final Integer MIN_SEVERITY = 1;
    private static final Integer MAX_SEVERITY = 5;

    /** One request item, after parsing. */
    public class SignalRequest {
        /** Idempotency key from the caller. */
        public String externalId;
        /** Salesforce account id, when the caller has it. */
        public String accountId;
        /** Account number, when the caller only knows its own key. */
        public String accountExternalId;
        /** Picklist value. */
        public String signalType;
        /** 1..5. */
        public Integer severity;
        /** yyyy-MM-dd, today or earlier. */
        public String occurredOn;
        /** Optional free text. */
        public String notes;
        /** Position in the submitted array, for correlation. */
        public Integer index;
    }

    /** One result row. */
    public class SignalResult {
        /** Echo of the caller's idempotency key. */
        public String externalId;
        /** created, updated, skipped or error. */
        public String status;
        /** Human readable outcome. */
        public String message;
        /** Signal id when the row was written. */
        public Id signalId;
        /** Position in the submitted array. */
        public Integer index;

        /**
         * @param index Position.
         * @param externalId Key.
         * @param status Outcome.
         * @param message Explanation.
         */
        public SignalResult(Integer index, String externalId, String status, String message) {
            this.index = index;
            this.externalId = externalId;
            this.status = status;
            this.message = message;
        }
    }

    /** Response envelope. */
    public class ApiResponse {
        /** Rows accepted and attempted. */
        public Integer processed = 0;
        /** Rows inserted. */
        public Integer created = 0;
        /** Rows updated (an idempotent retry). */
        public Integer updated = 0;
        /** Rows rejected. */
        public Integer failed = 0;
        /** Per-row detail, in submission order. */
        public List<SignalResult> results = new List<SignalResult>();
    }

    /**
     * @description Entry point. Reads RestContext, validates, upserts, writes the
     * response. Never throws: a thrown exception would return an HTML error page
     * to a machine client.
     */
    @HttpPost
    global static void doPost() {
        RestResponse response = RestContext.response;

        if (response == null) {
            response = new RestResponse();
            RestContext.response = response;
        }

        ApiResponse result;
        Integer statusCode = 200;

        try {
            String body = RestContext.request == null ||
                RestContext.request.requestBody == null
                ? null
                : RestContext.request.requestBody.toString();

            if (String.isBlank(body)) {
                statusCode = 400;
                result = errorResponse('The request body was empty. Send a JSON array of signals.');
            } else {
                Object parsed = JSON.deserializeUntyped(body);

                if (!(parsed instanceof List<Object>)) {
                    statusCode = 400;
                    result = errorResponse('The request body must be a JSON array of signal objects.');
                } else {
                    List<Object> items = (List<Object>) parsed;

                    if (items.size() > MAX_SIGNALS) {
                        statusCode = 413;
                        result = errorResponse(
                            'A maximum of ' +
                                MAX_SIGNALS +
                                ' signals can be sent per request; ' +
                                items.size() +
                                ' were received.'
                        );
                    } else {
                        result = processAll(items);
                    }
                }
            }
        } catch (JSONException malformed) {
            statusCode = 400;
            result = errorResponse('The request body is not valid JSON.');
        } catch (Exception unexpected) {
            RIQ_Logger.error(
                'RIQ_SignalRestResource',
                'Unhandled failure while processing an inbound signal batch.',
                unexpected
            );
            statusCode = 500;
            result = errorResponse('The request could not be processed. No changes were made.');
        }

        response.statusCode = statusCode;
        response.addHeader('Content-Type', 'application/json');
        response.responseBody = Blob.valueOf(JSON.serialize(result));
    }

    /**
     * @param message Explanation for the caller.
     * @return A response with no results and one failed row.
     */
    private static ApiResponse errorResponse(String message) {
        ApiResponse result = new ApiResponse();
        result.failed = 1;
        result.results.add(new SignalResult(0, null, 'error', message));
        return result;
    }

    /**
     * @param items Parsed request array.
     * @return Response with a result per submitted row.
     */
    private static ApiResponse processAll(List<Object> items) {
        ApiResponse result = new ApiResponse();
        List<SignalRequest> accepted = new List<SignalRequest>();
        Map<Integer, SignalResult> resultsByIndex = new Map<Integer, SignalResult>();
        Map<String, Integer> lastIndexByKey = new Map<String, Integer>();

        // Last occurrence wins: the newest version of a repeated key is the one
        // that gets written, and the earlier copies are reported as skipped so
        // the caller can see the collision instead of guessing.
        for (Integer i = 0; i < items.size(); i++) {
            SignalResult rejected = validate(items[i], i);

            if (rejected != null) {
                resultsByIndex.put(i, rejected);
                continue;
            }

            SignalRequest request = toRequest((Map<String, Object>) items[i], i);
            lastIndexByKey.put(request.externalId, i);
            accepted.add(request);
        }

        List<SignalRequest> toWrite = new List<SignalRequest>();

        for (SignalRequest request : accepted) {
            if (lastIndexByKey.get(request.externalId) != request.index) {
                resultsByIndex.put(
                    request.index,
                    new SignalResult(
                        request.index,
                        request.externalId,
                        'skipped',
                        'Duplicate externalId in this payload; the last occurrence was used.'
                    )
                );
            } else {
                toWrite.add(request);
            }
        }

        accepted = toWrite;

        if (!accepted.isEmpty()) {
            writeSignals(accepted, resultsByIndex);
        }

        for (Integer i = 0; i < items.size(); i++) {
            SignalResult row = resultsByIndex.get(i);
            result.results.add(row);
            result.processed++;

            if (row.status == 'created') {
                result.created++;
            } else if (row.status == 'updated') {
                result.updated++;
            } else if (row.status == 'error') {
                result.failed++;
            }
        }

        return result;
    }

    /**
     * @description Resolves accounts and upserts every accepted row in one DML.
     * @param accepted Validated requests.
     * @param resultsByIndex Results, keyed by submission index.
     */
    private static void writeSignals(List<SignalRequest> accepted, Map<Integer, SignalResult> resultsByIndex) {
        Set<Id> accountIds = new Set<Id>();
        Set<String> accountNumbers = new Set<String>();

        for (SignalRequest request : accepted) {
            if (String.isNotBlank(request.accountId) && isId(request.accountId)) {
                accountIds.add(Id.valueOf(request.accountId));
            } else if (String.isNotBlank(request.accountExternalId)) {
                accountNumbers.add(request.accountExternalId);
            }
        }

        Map<String, Id> accountIdByReference = resolveAccounts(accountIds, accountNumbers);
        List<RIQ_Health_Signal__c> toUpsert = new List<RIQ_Health_Signal__c>();
        List<SignalRequest> upsertedRequests = new List<SignalRequest>();
        Set<String> picklistValues = signalTypes();

        for (SignalRequest request : accepted) {
            String reference = String.isNotBlank(request.accountId) ? request.accountId : request.accountExternalId;
            Id accountId = accountIdByReference.get(reference);

            if (accountId == null) {
                resultsByIndex.put(
                    request.index,
                    new SignalResult(
                        request.index,
                        request.externalId,
                        'error',
                        'No account matches ' + (reference == null ? 'the supplied reference' : reference) + '.'
                    )
                );
                continue;
            }

            if (!picklistValues.contains(request.signalType)) {
                resultsByIndex.put(
                    request.index,
                    new SignalResult(
                        request.index,
                        request.externalId,
                        'error',
                        '"' + request.signalType + '" is not a known signal type.'
                    )
                );
                continue;
            }

            try {
                toUpsert.add(
                    new RIQ_Health_Signal__c(
                        Account__c = accountId,
                        RIQ_External_Key__c = request.externalId,
                        Signal_Type__c = request.signalType,
                        Severity__c = request.severity,
                        Occurred_On__c = Date.valueOf(request.occurredOn),
                        Notes__c = request.notes
                    )
                );
                upsertedRequests.add(request);
            } catch (Exception invalidDate) {
                resultsByIndex.put(
                    request.index,
                    new SignalResult(request.index, request.externalId, 'error', 'occurredOn must be yyyy-MM-dd.')
                );
            }
        }

        if (toUpsert.isEmpty()) {
            return;
        }

        // USER_MODE: the integration user is a real user with real permissions,
        // so field-level security is what stops a misconfigured integration from
        // writing fields it was never granted.
        List<Database.UpsertResult> saveResults = Database.upsert(
            toUpsert,
            RIQ_Health_Signal__c.RIQ_External_Key__c,
            false,
            AccessLevel.USER_MODE
        );

        for (Integer i = 0; i < saveResults.size(); i++) {
            Database.UpsertResult saveResult = saveResults[i];
            SignalRequest request = upsertedRequests[i];
            SignalResult row;

            if (saveResult.isSuccess()) {
                row = new SignalResult(
                    request.index,
                    request.externalId,
                    saveResult.isCreated() ? 'created' : 'updated',
                    saveResult.isCreated() ? 'Signal created.' : 'Signal updated (idempotent retry).'
                );
                row.signalId = saveResult.getId();
            } else {
                row = new SignalResult(
                    request.index,
                    request.externalId,
                    'error',
                    describeErrors(saveResult.getErrors())
                );
            }

            resultsByIndex.put(request.index, row);
        }
    }

    /**
     * @param accountIds Account ids from the payload.
     * @param accountNumbers Account numbers from the payload.
     * @return Map of the caller's reference to a resolved account id.
     */
    private static Map<String, Id> resolveAccounts(Set<Id> accountIds, Set<String> accountNumbers) {
        Map<String, Id> byReference = new Map<String, Id>();

        if (accountIds.isEmpty() && accountNumbers.isEmpty()) {
            return byReference;
        }

        try {
            for (Account account : [
                SELECT Id, AccountNumber
                FROM Account
                WHERE Id IN :accountIds OR AccountNumber IN :accountNumbers
                WITH USER_MODE
            ]) {
                byReference.put(account.Id, account.Id);

                if (String.isNotBlank(account.AccountNumber)) {
                    byReference.put(account.AccountNumber, account.Id);
                }
            }
        } catch (QueryException noAccess) {
            // A caller without account access gets a per-record "no account"
            // error, not a 500: the request was understood, it was not permitted.
            RIQ_Logger.warn(
                'RIQ_SignalRestResource',
                'Account lookup was refused by sharing or field permissions.',
                noAccess
            );
            return new Map<String, Id>();
        }

        return byReference;
    }

    /**
     * @param item One array element.
     * @param index Position.
     * @return A failure result, or null when the item is acceptable.
     */
    private static SignalResult validate(Object item, Integer index) {
        if (!(item instanceof Map<String, Object>)) {
            return new SignalResult(index, null, 'error', 'Each signal must be a JSON object.');
        }

        Map<String, Object> values = (Map<String, Object>) item;
        String externalId = stringValue(values.get('externalId'));

        if (String.isBlank(externalId)) {
            return new SignalResult(index, null, 'error', 'externalId is required.');
        }

        if (externalId.length() > 120) {
            return new SignalResult(index, externalId, 'error', 'externalId must be 120 characters or fewer.');
        }

        String accountId = stringValue(values.get('accountId'));
        String accountExternalId = stringValue(values.get('accountExternalId'));

        if (String.isBlank(accountId) && String.isBlank(accountExternalId)) {
            return new SignalResult(index, externalId, 'error', 'accountId or accountExternalId is required.');
        }

        if (String.isNotBlank(accountId) && !isId(accountId)) {
            return new SignalResult(index, externalId, 'error', 'accountId is not a valid Salesforce id.');
        }

        if (String.isBlank(stringValue(values.get('signalType')))) {
            return new SignalResult(index, externalId, 'error', 'signalType is required.');
        }

        Integer severity = toInteger(values.get('severity'));

        if (severity == null || severity < MIN_SEVERITY || severity > MAX_SEVERITY) {
            return new SignalResult(
                index,
                externalId,
                'error',
                'severity must be a whole number between ' + MIN_SEVERITY + ' and ' + MAX_SEVERITY + '.'
            );
        }

        String occurredOn = stringValue(values.get('occurredOn'));

        if (String.isBlank(occurredOn)) {
            return new SignalResult(index, externalId, 'error', 'occurredOn is required (yyyy-MM-dd).');
        }

        try {
            if (Date.valueOf(occurredOn) > Date.today()) {
                return new SignalResult(index, externalId, 'error', 'occurredOn cannot be in the future.');
            }
        } catch (Exception notADate) {
            return new SignalResult(index, externalId, 'error', 'occurredOn must be yyyy-MM-dd.');
        }

        String notes = stringValue(values.get('notes'));

        if (notes != null && notes.length() > MAX_NOTES_LENGTH) {
            return new SignalResult(
                index,
                externalId,
                'error',
                'notes must be ' + MAX_NOTES_LENGTH + ' characters or fewer.'
            );
        }

        return null;
    }

    /**
     * @param values Validated item.
     * @param index Position.
     * @return Parsed request.
     */
    private static SignalRequest toRequest(Map<String, Object> values, Integer index) {
        SignalRequest request = new SignalRequest();
        request.index = index;
        request.externalId = stringValue(values.get('externalId'));
        request.accountId = stringValue(values.get('accountId'));
        request.accountExternalId = stringValue(values.get('accountExternalId'));
        request.signalType = stringValue(values.get('signalType'));
        request.severity = toInteger(values.get('severity'));
        request.occurredOn = stringValue(values.get('occurredOn'));
        request.notes = stringValue(values.get('notes'));
        return request;
    }

    /**
     * @param errors DML errors.
     * @return A safe, non-technical summary. Raw exception text never reaches a
     *         caller, because it can contain record ids and field names.
     */
    private static String describeErrors(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) {
            return 'The signal could not be saved.';
        }

        List<String> messages = new List<String>();

        for (Database.Error error : errors) {
            messages.add(error.getMessage());
        }

        // The operator gets the field names and status codes; the caller gets a
        // sentence. DML text can name fields and record ids the integration user
        // was never meant to see, and a machine client gains nothing from it.
        RIQ_Logger.warn('RIQ_SignalRestResource', 'Signal upsert failed: ' + String.join(messages, '; '));
        return 'The signal could not be saved. Check the values and the integration user\'s permissions.';
    }

    /**
     * @return Valid signal type picklist values.
     */
    private static Set<String> signalTypes() {
        Set<String> values = new Set<String>();

        for (Schema.PicklistEntry entry : RIQ_Health_Signal__c.Signal_Type__c.getDescribe().getPicklistValues()) {
            values.add(entry.getValue());
        }

        return values;
    }

    /**
     * @param value Raw JSON value.
     * @return String form, or null.
     */
    private static String stringValue(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    /**
     * @param value Raw JSON value.
     * @return Integer, or null when it is not a whole number.
     */
    private static Integer toInteger(Object value) {
        if (value == null) {
            return null;
        }

        try {
            return Integer.valueOf(String.valueOf(value));
        } catch (Exception notAnInteger) {
            return null;
        }
    }

    /**
     * @param value Candidate id.
     * @return True for a 15 or 18 character Salesforce id.
     */
    private static Boolean isId(String value) {
        if (String.isBlank(value) || (value.length() != 15 && value.length() != 18)) {
            return false;
        }

        try {
            return Id.valueOf(value) != null && ((String) Id.valueOf(value)).length() == value.length();
        } catch (Exception notAnId) {
            return false;
        }
    }
}
