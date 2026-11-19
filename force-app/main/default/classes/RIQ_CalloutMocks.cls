/**
 * @description Callout mocks for the AI insight tests. Nothing here talks to a
 * real model: the point is to prove the service behaves for every response the
 * provider can give, including the ones that are not JSON. Bodies are shaped
 * like Groq's OpenAI-compatible chat completions responses.
 */
@IsTest
public class RIQ_CalloutMocks {
    /** A well-formed Groq chat completion wrapping an insight in message.content. */
    public static final String GROQ_SUCCESS_BODY =
        '{"id":"chatcmpl-1","object":"chat.completion","model":"openai/gpt-oss-120b",' +
        '"choices":[{"index":0,"message":{"role":"assistant","content":' +
        JSON.serialize(
            '{"summary":"Usage is down and the sponsor left.","nextBestAction":"Book an executive call.",' +
            '"riskReasons":["Sponsor departed","Usage down 30%"]}'
        ) +
        '},"finish_reason":"stop"}],"usage":{"total_tokens":312}}';

    /** The same insight, wrapped in a Markdown code fence inside message.content. */
    public static final String FENCED_BODY =
        '{"choices":[{"index":0,"message":{"role":"assistant","content":' +
        JSON.serialize(
            '```json\n{"summary":"Fenced summary.","nextBestAction":"Call them.","riskReasons":["Fenced reason"]}\n```'
        ) +
        '}}]}';

    /** JSON mode was requested but the model answered with prose. */
    public static final String PROSE_BODY = '{"choices":[{"index":0,"message":{"role":"assistant","content":"I think this account is fine."}}]}';

    /** A 200 with nothing usable inside. */
    public static final String EMPTY_CHOICES_BODY = '{"choices":[]}';

    /** Responds with the configured status, body and optional Retry-After. */
    public class Responder implements HttpCalloutMock {
        /** Requests received, so a test can prove nothing was retried. */
        public Integer callCount = 0;

        private final Integer statusCode;
        private final String body;
        private final String retryAfter;

        /**
         * @param statusCode HTTP status to return.
         * @param body Response body.
         */
        public Responder(Integer statusCode, String body) {
            this(statusCode, body, null);
        }

        /**
         * @param statusCode HTTP status to return.
         * @param body Response body.
         * @param retryAfter Value for the Retry-After header, when simulating a 429.
         */
        public Responder(Integer statusCode, String body, String retryAfter) {
            this.statusCode = statusCode;
            this.body = body;
            this.retryAfter = retryAfter;
        }

        /**
         * @param request Outbound request.
         * @return The canned response.
         */
        public HttpResponse respond(HttpRequest request) {
            callCount++;

            HttpResponse response = new HttpResponse();
            response.setStatusCode(statusCode);
            response.setBody(body);

            if (String.isNotBlank(retryAfter)) {
                response.setHeader('Retry-After', retryAfter);
            }

            return response;
        }
    }

    /** Simulates a callout that never completes. */
    public class Timeout implements HttpCalloutMock {
        /**
         * @param request Outbound request.
         * @return Never returns.
         */
        public HttpResponse respond(HttpRequest request) {
            throw new CalloutException('Read timed out');
        }
    }

    /** Records every request and answers 200 with a usable insight. */
    public class Recorder implements HttpCalloutMock {
        /** Number of requests received. */
        public Integer callCount = 0;
        /** Body of the last request. */
        public String lastBody;
        /** Endpoint of the last request. */
        public String lastEndpoint;
        /** Content-Type of the last request. */
        public String lastContentType;

        /**
         * @param request Outbound request.
         * @return A successful model response.
         */
        public HttpResponse respond(HttpRequest request) {
            callCount++;
            lastBody = request.getBody();
            lastEndpoint = request.getEndpoint();
            lastContentType = request.getHeader('Content-Type');

            return new Responder(200, GROQ_SUCCESS_BODY).respond(request);
        }
    }
}
