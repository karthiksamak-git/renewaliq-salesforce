/**
 * @description Callout mocks for the AI insight tests. Nothing here talks to a
 * real model: the point is to prove the service behaves for every response the
 * provider can give, including the ones that are not JSON.
 */
@IsTest
public class RIQ_CalloutMocks {
    /** A well-formed Anthropic Messages response wrapping an insight. */
    public static final String ANTHROPIC_SUCCESS_BODY =
        '{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":' +
        JSON.serialize(
            '{"summary":"Usage is down and the sponsor left.","nextBestAction":"Book an executive call.",' +
            '"riskReasons":["Sponsor departed","Usage down 30%"]}'
        ) +
        '}]}';

    /** The same insight, wrapped in a Markdown code fence. */
    public static final String FENCED_BODY =
        '{"content":[{"type":"text","text":"```json\\n{\\"summary\\":\\"Fenced summary.\\",' +
        '\\"nextBestAction\\":\\"Call them.\\",\\"riskReasons\\":[\\"Fenced reason\\"]}\\n```"}]}';

    /** An OpenAI-compatible chat completion shape. */
    public static final String OPENAI_BODY =
        '{"choices":[{"index":0,"message":{"role":"assistant","content":' +
        JSON.serialize('{"summary":"OpenAI style summary.","nextBestAction":"Follow up.","riskReasons":[]}') +
        '}}]}';

    /** Responds with the configured status and body. */
    public class Responder implements HttpCalloutMock {
        private final Integer statusCode;
        private final String body;

        /**
         * @param statusCode HTTP status to return.
         * @param body Response body.
         */
        public Responder(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body;
        }

        /**
         * @param request Outbound request.
         * @return The canned response.
         */
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(statusCode);
            response.setBody(body);
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
        /** Value of the API version header on the last request. */
        public String lastAnthropicVersion;

        /**
         * @param request Outbound request.
         * @return A successful model response.
         */
        public HttpResponse respond(HttpRequest request) {
            callCount++;
            lastBody = request.getBody();
            lastEndpoint = request.getEndpoint();

            lastAnthropicVersion = request.getHeader('anthropic-version');

            return new Responder(200, ANTHROPIC_SUCCESS_BODY).respond(request);
        }
    }
}
