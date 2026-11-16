/* eslint-disable @lwc/lwc/no-async-operation, @lwc/lwc/no-unexpected-wire-adapter-usages -- test helpers drive timers and the message-context wire */
import { createElement } from 'lwc';
import RiqSignalLogger from 'c/riqSignalLogger';
import getSignalTypes from '@salesforce/apex/RIQ_AccountHealthController.getSignalTypes';
import logSignal from '@salesforce/apex/RIQ_AccountHealthController.logSignal';
import { MessageContext, publish } from 'lightning/messageService';

jest.mock('@salesforce/apex/RIQ_AccountHealthController.getSignalTypes', () => ({ default: jest.fn() }), {
  virtual: true
});
jest.mock('@salesforce/apex/RIQ_AccountHealthController.logSignal', () => ({ default: jest.fn() }), { virtual: true });
jest.mock(
  'lightning/messageService',
  () => {
    const actual = jest.requireActual('lightning/messageService');
    return {
      ...actual,
      subscribe: jest.fn(() => 'sub'),
      unsubscribe: jest.fn(),
      publish: jest.fn()
    };
  },
  { virtual: true }
);

const ACCOUNT_ID = '001000000000001AAA';

// A macrotask, not a microtask: LWC commits the DOM between them.
const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

/**
 * Base components in the jest stubs receive their attributes as properties, so
 * "[name=\"x\"]" selectors never match. Address them by tag and property.
 */
function field(element, tag, name) {
  return Array.from(element.shadowRoot.querySelectorAll(tag)).find((node) => node.name === name);
}

async function createLogger() {
  const element = createElement('c-riq-signal-logger', { is: RiqSignalLogger });
  element.recordId = ACCOUNT_ID;
  document.body.appendChild(element);
  await flushPromises();
  return element;
}

function change(element, tag, name, value) {
  field(element, tag, name).dispatchEvent(new CustomEvent('change', { detail: { value } }));
}

function submit(element) {
  element.shadowRoot
    .querySelector('form')
    .dispatchEvent(new CustomEvent('submit', { bubbles: true, cancelable: true }));
}

describe('c-riq-signal-logger', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    getSignalTypes.mockResolvedValue(['Support Escalation', 'Usage Drop', 'Champion Left']);
  });

  afterEach(() => {
    jest.useRealTimers();
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it('loads the signal type options', async () => {
    const element = await createLogger();

    const options = field(element, 'lightning-combobox', 'signalType');
    expect(options).toBeDefined();
    expect(options.options.map((option) => option.value)).toEqual([
      'Support Escalation',
      'Usage Drop',
      'Champion Left'
    ]);
    expect(getSignalTypes).toHaveBeenCalledTimes(1);
  });

  it('shows the Apex message when the options cannot be loaded', async () => {
    getSignalTypes.mockRejectedValue({ body: { message: 'Could not load signal types.' } });
    const element = await createLogger();

    expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toContain('Could not load signal types.');
  });

  it('blocks submission when no signal type is chosen', async () => {
    const element = await createLogger();

    submit(element);
    await flushPromises();

    expect(logSignal).not.toHaveBeenCalled();
  });

  it('blocks submission for a future date, then accepts a valid one', async () => {
    const element = await createLogger();

    change(element, 'lightning-combobox', 'signalType', 'Usage Drop');
    change(element, 'lightning-input', 'occurredOn', '2999-01-01');
    submit(element);
    await flushPromises();

    expect(logSignal).not.toHaveBeenCalled();

    change(element, 'lightning-input', 'occurredOn', '2026-11-01');
    submit(element);
    await flushPromises();

    expect(logSignal).toHaveBeenCalledTimes(1);
  });

  it('logs the signal with the selected values', async () => {
    logSignal.mockResolvedValue('a01000000000001AAA');
    const element = await createLogger();
    const toastHandler = jest.fn();
    element.addEventListener('lightning__showtoast', toastHandler);

    change(element, 'lightning-combobox', 'signalType', 'Champion Left');
    change(element, 'lightning-combobox', 'severity', '5');
    change(element, 'lightning-input', 'occurredOn', '2026-11-10');
    change(element, 'lightning-textarea', 'notes', 'Our sponsor moved to a new company');
    submit(element);
    await flushPromises();

    expect(logSignal).toHaveBeenCalledWith({
      accountId: ACCOUNT_ID,
      signalType: 'Champion Left',
      severity: 5,
      occurredOn: '2026-11-10',
      notes: 'Our sponsor moved to a new company'
    });

    const toast = toastHandler.mock.calls[0][0];
    expect(toast.detail.title).toBe('Signal logged');
    expect(toast.detail.variant).toBe('success');
  });

  it('shows a score-updating state and publishes a refresh afterwards', async () => {
    logSignal.mockResolvedValue('a01000000000001AAA');
    const element = await createLogger();
    // The stub MessageContext is a test wire adapter: it emits only on demand.
    MessageContext.emit('riq-message-context');
    await flushPromises();
    jest.useFakeTimers();

    change(element, 'lightning-combobox', 'signalType', 'Usage Drop');
    submit(element);
    await Promise.resolve();
    await Promise.resolve();

    expect(element.shadowRoot.querySelector('.riq-logger__status')).not.toBeNull();
    expect(publish).not.toHaveBeenCalled();

    jest.advanceTimersByTime(4000);
    await Promise.resolve();
    await Promise.resolve();

    expect(publish).toHaveBeenCalledWith(expect.anything(), expect.anything(), {
      accountId: ACCOUNT_ID
    });
    expect(element.shadowRoot.querySelector('.riq-logger__status')).toBeNull();
  });

  it('clears the form after a successful submit', async () => {
    logSignal.mockResolvedValue('a01000000000001AAA');
    const element = await createLogger();

    change(element, 'lightning-combobox', 'signalType', 'Usage Drop');
    submit(element);
    await flushPromises();

    expect(field(element, 'lightning-combobox', 'signalType').value).toBeUndefined();
  });

  it('toasts a friendly error when the server rejects the signal', async () => {
    logSignal.mockRejectedValue({ body: { message: 'Severity must be between 1 and 5.' } });
    const element = await createLogger();
    const toastHandler = jest.fn();
    element.addEventListener('lightning__showtoast', toastHandler);

    change(element, 'lightning-combobox', 'signalType', 'Usage Drop');
    submit(element);
    await flushPromises();

    const toast = toastHandler.mock.calls[0][0];
    expect(toast.detail.variant).toBe('error');
    expect(toast.detail.message).toBe('Severity must be between 1 and 5.');
    expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toContain(
      'Severity must be between 1 and 5.'
    );
  });

  it('resets to defaults when Clear is pressed', async () => {
    const element = await createLogger();

    change(element, 'lightning-combobox', 'signalType', 'Usage Drop');
    element.shadowRoot.querySelectorAll('lightning-button')[1].click();
    await flushPromises();

    expect(field(element, 'lightning-combobox', 'signalType').value).toBeUndefined();
    expect(field(element, 'lightning-input', 'occurredOn').value).toBe(RiqSignalLogger.todayIso());
  });
});
