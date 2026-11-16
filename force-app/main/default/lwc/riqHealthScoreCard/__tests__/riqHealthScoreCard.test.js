/* eslint-disable @lwc/lwc/no-async-operation, @lwc/lwc/no-unexpected-wire-adapter-usages -- test helpers drive timers and the message-context wire */
import { createElement } from 'lwc';
import RiqHealthScoreCard from 'c/riqHealthScoreCard';
import getHealthCard from '@salesforce/apex/RIQ_AccountHealthController.getHealthCard';
import recalculate from '@salesforce/apex/RIQ_AccountHealthController.recalculate';
import { MessageContext, subscribe, unsubscribe } from 'lightning/messageService';

jest.mock(
  '@salesforce/apex/RIQ_AccountHealthController.getHealthCard',
  () => ({
    // Required inside the factory: jest.mock may not close over imports.
    default: jest.requireActual('@salesforce/sfdx-lwc-jest').createApexTestWireAdapter(jest.fn())
  }),
  { virtual: true }
);
jest.mock('@salesforce/apex/RIQ_AccountHealthController.recalculate', () => ({ default: jest.fn() }), {
  virtual: true
});
jest.mock(
  'lightning/messageService',
  () => {
    const actual = jest.requireActual('lightning/messageService');
    return {
      ...actual,
      subscribe: jest.fn(() => 'riq-refresh-sub'),
      unsubscribe: jest.fn(),
      publish: jest.fn()
    };
  },
  { virtual: true }
);

const ACCOUNT_ID = '001000000000001AAA';

const CARD = {
  accountId: ACCOUNT_ID,
  accountName: 'Acme',
  score: 42,
  status: 'At Risk',
  churnProbability: 61,
  arr: 480000,
  contractEndDate: '2026-12-31',
  lastScored: '2026-11-15T09:30:00.000Z',
  canRecalculate: true,
  drivers: [
    { signalType: 'Support Escalation', severity: 4, points: 22, explanation: 'Three P1s in 30 days' },
    { signalType: 'Usage Drop', severity: 3, points: 11, explanation: 'Active users down 30%' }
  ],
  history: [
    { scoreDate: '2026-10-01', score: 70 },
    { scoreDate: '2026-11-01', score: 55 },
    { scoreDate: '2026-11-15', score: 42 }
  ]
};

// A macrotask, not a microtask: LWC commits the DOM between them.
const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

async function createCard(props = { recordId: ACCOUNT_ID }) {
  const element = createElement('c-riq-health-score-card', { is: RiqHealthScoreCard });
  Object.assign(element, props);
  document.body.appendChild(element);
  await flushPromises();
  return element;
}

describe('c-riq-health-score-card', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it('requests the card for the record it is placed on', async () => {
    await createCard();

    expect(getHealthCard.getLastConfig()).toEqual({ accountId: ACCOUNT_ID });
  });

  it('renders the score, status, churn and gauge geometry', async () => {
    const element = await createCard();
    getHealthCard.emit(CARD);
    await flushPromises();

    const text = element.shadowRoot.textContent;
    expect(text).toContain('42');
    expect(text).toContain('At Risk');
    expect(text).toContain('61%');
    expect(text).toContain('$480K');
    expect(text).toContain('2026-12-31');

    const gauge = element.shadowRoot.querySelector('circle.riq-gauge__value');
    expect(gauge.getAttribute('stroke-dasharray')).not.toBeNull();
    expect(gauge.getAttribute('stroke')).toBe('#fe9339');
  });

  it('renders the top drivers with their points', async () => {
    const element = await createCard();
    getHealthCard.emit(CARD);
    await flushPromises();

    const drivers = element.shadowRoot.querySelectorAll('.riq-drivers__item');
    expect(drivers).toHaveLength(2);
    expect(drivers[0].textContent).toContain('Support Escalation');
    expect(drivers[0].textContent).toContain('−22 pts');
  });

  it('draws the sparkline from the history, oldest first', async () => {
    const element = await createCard();
    getHealthCard.emit(CARD);
    await flushPromises();

    const line = element.shadowRoot.querySelector('polyline.riq-sparkline__line');
    expect(line.getAttribute('points').split(' ')).toHaveLength(3);
    expect(element.shadowRoot.textContent).toContain('3 points · -28 over the window');
  });

  it('handles a card with no drivers or history', async () => {
    const element = await createCard();
    getHealthCard.emit({ ...CARD, score: null, status: 'Healthy', drivers: [], history: [] });
    await flushPromises();

    expect(element.shadowRoot.querySelector('.riq-drivers__item')).toBeNull();
    expect(element.shadowRoot.querySelector('polyline.riq-sparkline__line')).toBeNull();
    expect(element.shadowRoot.textContent).toContain('No history yet');
  });

  it('shows the Apex message when the card cannot be loaded', async () => {
    const element = await createCard();
    getHealthCard.error(new Error('You cannot view this account.'));
    await flushPromises();

    expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toContain('You cannot view this account.');
  });

  it('recalculates and toasts the new score', async () => {
    recalculate.mockResolvedValue({ ...CARD, score: 66, status: 'Healthy' });
    const element = await createCard();
    getHealthCard.emit(CARD);
    await flushPromises();

    const toastHandler = jest.fn();
    element.addEventListener('lightning__showtoast', toastHandler);

    element.shadowRoot.querySelector('lightning-button').click();
    await flushPromises();
    await flushPromises();

    expect(recalculate).toHaveBeenCalledWith({ accountId: ACCOUNT_ID });
    expect(toastHandler).toHaveBeenCalledTimes(1);
    expect(toastHandler.mock.calls[0][0].detail.title).toBe('Health score recalculated');
    expect(element.shadowRoot.textContent).toContain('66');
  });

  it('toasts a friendly error when recalculation is refused', async () => {
    recalculate.mockRejectedValue({ body: { message: 'You do not have permission to recalculate.' } });
    const element = await createCard();
    getHealthCard.emit(CARD);
    await flushPromises();

    const toastHandler = jest.fn();
    element.addEventListener('lightning__showtoast', toastHandler);

    element.shadowRoot.querySelector('lightning-button').click();
    await flushPromises();

    const toast = toastHandler.mock.calls[0][0];
    expect(toast.detail.variant).toBe('error');
    expect(toast.detail.message).toBe('You do not have permission to recalculate.');
  });

  it('hints that the user cannot recalculate without the permission', async () => {
    const element = await createCard();
    getHealthCard.emit({ ...CARD, canRecalculate: false });
    await flushPromises();

    const button = element.shadowRoot.querySelector('lightning-button');
    expect(button.title).toBe('Your permission set does not allow recalculating scores.');
  });

  it('subscribes to score refresh messages and unsubscribes on disconnect', async () => {
    const element = await createCard();

    // The stub MessageContext is a test wire adapter: it emits only on demand.
    MessageContext.emit('riq-message-context');
    await flushPromises();

    expect(subscribe).toHaveBeenCalledTimes(1);

    document.body.removeChild(element);
    expect(unsubscribe).toHaveBeenCalledWith('riq-refresh-sub');
  });
});
