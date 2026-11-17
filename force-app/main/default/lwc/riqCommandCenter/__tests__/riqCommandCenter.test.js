/* eslint-disable @lwc/lwc/no-async-operation -- the test helper flushes a macrotask */
import { createElement } from 'lwc';
import RiqCommandCenter from 'c/riqCommandCenter';
import getKpis from '@salesforce/apex/RIQ_DashboardController.getKpis';
import getStatusDistribution from '@salesforce/apex/RIQ_DashboardController.getStatusDistribution';
import getAtRiskAccounts from '@salesforce/apex/RIQ_DashboardController.getAtRiskAccounts';
import getRowCount from '@salesforce/apex/RIQ_DashboardController.getRowCount';
import getOwners from '@salesforce/apex/RIQ_DashboardController.getOwners';
import recalculate from '@salesforce/apex/RIQ_AccountHealthController.recalculate';
import { subscribe, unsubscribe } from 'lightning/empApi';
import { loadScript } from 'lightning/platformResourceLoader';

jest.mock('@salesforce/apex/RIQ_DashboardController.getKpis', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/RIQ_DashboardController.getStatusDistribution', () => ({ default: jest.fn() }), {
  virtual: true
});
jest.mock('@salesforce/apex/RIQ_DashboardController.getAtRiskAccounts', () => ({ default: jest.fn() }), {
  virtual: true
});
jest.mock('@salesforce/apex/RIQ_DashboardController.getRowCount', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/RIQ_DashboardController.getOwners', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/RIQ_AccountHealthController.recalculate', () => ({ default: jest.fn() }), {
  virtual: true
});
jest.mock(
  'lightning/empApi',
  () => ({
    subscribe: jest.fn(() => Promise.resolve({ id: 'riq-sub-1' })),
    unsubscribe: jest.fn(() => Promise.resolve(true))
  }),
  { virtual: true }
);
jest.mock(
  'lightning/platformResourceLoader',
  () => ({ loadScript: jest.fn(() => Promise.reject(new Error('blocked by LWS'))) }),
  { virtual: true }
);

const KPIS = {
  accountCount: 12,
  totalArr: 4200000,
  arrAtRisk: 1200000,
  averageScore: 64,
  criticalCount: 3,
  renewalsDue: 5,
  renewalWindowDays: 90
};

const SLICES = [
  { label: 'Critical', count: 3 },
  { label: 'At Risk', count: 4 },
  { label: 'Watch', count: 2 },
  { label: 'Healthy', count: 3 }
];

const ROWS = [
  {
    accountId: '001000000000001AAA',
    name: 'Acme',
    recordUrl: '/001000000000001AAA',
    ownerName: 'Priya',
    status: 'Critical',
    score: 31,
    churnProbability: 72,
    arr: 480000,
    daysToRenewal: 12,
    lastScored: '2026-11-15T09:30:00.000Z'
  }
];

// A macrotask, not a microtask: LWC commits the DOM between them.
const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

/**
 * Base components in the jest stubs receive their attributes as properties, so
 * "[name=\"x\"]" selectors never match. Address them by tag and property.
 */
function field(element, tag, name) {
  return Array.from(element.shadowRoot.querySelectorAll(tag)).find((node) => node.name === name);
}

function buttonByLabel(element, label) {
  return Array.from(element.shadowRoot.querySelectorAll('lightning-button')).find((button) => button.label === label);
}

function kpiValue(element, key) {
  const tile = element.shadowRoot.querySelector(`.riq-kpi[data-key="${key}"]`);
  return tile ? tile.querySelector('.riq-kpi__value') : null;
}

function resolveAllWith({ rows = ROWS, kpis = KPIS, slices = SLICES, rowCount = 12 } = {}) {
  getKpis.mockResolvedValue(kpis);
  getStatusDistribution.mockResolvedValue(slices);
  getAtRiskAccounts.mockResolvedValue(rows);
  getRowCount.mockResolvedValue(rowCount);
  getOwners.mockResolvedValue([{ ownerId: '005000000000001AAA', ownerName: 'Priya' }]);
}

async function createDashboard() {
  const element = createElement('c-riq-command-center', { is: RiqCommandCenter });
  document.body.appendChild(element);
  await flushPromises();
  await flushPromises();
  return element;
}

describe('c-riq-command-center', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it('shows a spinner while the first render is in flight', () => {
    resolveAllWith();
    const element = createElement('c-riq-command-center', { is: RiqCommandCenter });
    document.body.appendChild(element);

    expect(element.shadowRoot.querySelector('lightning-spinner')).not.toBeNull();
  });

  it('renders five KPI tiles in rupees, with the full amount on hover', async () => {
    resolveAllWith();
    const element = await createDashboard();

    const tiles = element.shadowRoot.querySelectorAll('.riq-kpi');
    expect(tiles).toHaveLength(5);

    expect(kpiValue(element, 'arr').textContent).toBe('₹42 L');
    expect(kpiValue(element, 'arr').getAttribute('title')).toBe('₹42,00,000 total annual recurring revenue in scope.');

    expect(kpiValue(element, 'risk').textContent).toBe('₹12 L');
    expect(kpiValue(element, 'risk').getAttribute('title')).toContain(
      'Yearly revenue from customers rated At Risk or Critical'
    );

    expect(kpiValue(element, 'critical').textContent).toBe('3');
    expect(kpiValue(element, 'score').textContent).toBe('64');
    expect(kpiValue(element, 'renewals').textContent).toBe('5');
  });

  it('renders one table row with INR, a labelled status badge and IST last scored', async () => {
    resolveAllWith();
    const element = await createDashboard();

    const bodyRows = element.shadowRoot.querySelectorAll('tbody tr');
    expect(bodyRows).toHaveLength(1);

    const text = bodyRows[0].textContent;
    expect(text).toContain('Acme');
    expect(text).toContain('31');
    expect(text).toContain('Critical');
    expect(text).toContain('72%');
    expect(text).toContain('₹4.8 L');
    expect(text).toContain('12 days');
    expect(text).not.toContain('2026-11-15T');

    const badge = bodyRows[0].querySelector('.riq-badge');
    expect(badge.textContent).toContain('Critical');
    expect(badge.getAttribute('style')).toContain('#ba0517');
  });

  it('shows the visible count and states that the lowest score comes first', async () => {
    resolveAllWith();
    const element = await createDashboard();

    const header = element.shadowRoot.querySelector('.riq-panel__head').textContent;
    expect(header).toContain('Showing 1 of 12');
    expect(header).toContain('Lowest health score first');
  });

  it('asks the server for the lowest score first by default', async () => {
    resolveAllWith();
    await createDashboard();

    const firstCall = getAtRiskAccounts.mock.calls[0][0];
    expect(firstCall.sortBy).toBe('score');
    expect(firstCall.sortDirection).toBe('asc');
    expect(getRowCount).toHaveBeenCalledWith({
      statusFilter: 'All',
      ownerId: null,
      renewalWindowDays: 90
    });
  });

  it('subscribes to the platform event and unsubscribes on disconnect', async () => {
    resolveAllWith();
    const element = await createDashboard();

    expect(subscribe).toHaveBeenCalledTimes(1);
    expect(subscribe.mock.calls[0][0]).toBe('/event/RIQ_Health_Status_Change__e');
    expect(subscribe.mock.calls[0][1]).toBe(-1);

    document.body.removeChild(element);
    expect(unsubscribe).toHaveBeenCalledTimes(1);
  });

  it('refreshes and toasts when a health status event arrives', async () => {
    resolveAllWith();
    const element = await createDashboard();
    const toastHandler = jest.fn();
    element.addEventListener('lightning__showtoast', toastHandler);

    const handler = subscribe.mock.calls[0][2];
    handler({
      data: { payload: { OldStatus__c: 'Watch', NewStatus__c: 'Critical', Score__c: 28 } }
    });
    await flushPromises();

    expect(toastHandler).toHaveBeenCalledTimes(1);
    expect(getKpis).toHaveBeenCalledTimes(2);
    expect(getAtRiskAccounts).toHaveBeenCalledTimes(2);
  });

  it('re-queries with the selected status filter and owner', async () => {
    resolveAllWith();
    const element = await createDashboard();

    field(element, 'lightning-combobox', 'status').dispatchEvent(
      new CustomEvent('change', { detail: { value: 'Healthy' } })
    );
    field(element, 'lightning-combobox', 'owner').dispatchEvent(
      new CustomEvent('change', { detail: { value: '005000000000001AAA' } })
    );
    await flushPromises();

    const lastCall = getAtRiskAccounts.mock.calls[getAtRiskAccounts.mock.calls.length - 1][0];
    expect(lastCall.statusFilter).toBe('Healthy');
    expect(lastCall.ownerId).toBe('005000000000001AAA');
  });

  it('sorts through the table header buttons', async () => {
    resolveAllWith();
    const element = await createDashboard();

    element.shadowRoot.querySelector('button[data-key="churn"]').click();
    await flushPromises();

    const lastCall = getAtRiskAccounts.mock.calls[getAtRiskAccounts.mock.calls.length - 1][0];
    expect(lastCall.sortBy).toBe('churn');
    expect(lastCall.sortDirection).toBe('asc');
  });

  it('marks the sorted column for assistive technology', async () => {
    resolveAllWith();
    const element = await createDashboard();

    const sorted = Array.from(element.shadowRoot.querySelectorAll('th')).find(
      (header) => header.getAttribute('aria-sort') === 'ascending'
    );

    expect(sorted.textContent).toContain('Health score');
  });

  it('recalculates a row and reloads the dashboard', async () => {
    resolveAllWith();
    recalculate.mockResolvedValue({ accountName: 'Acme', score: 44, status: 'At Risk' });
    const element = await createDashboard();
    const toastHandler = jest.fn();
    element.addEventListener('lightning__showtoast', toastHandler);

    element.shadowRoot.querySelector('button[data-id="001000000000001AAA"]').click();
    await flushPromises();
    await flushPromises();

    expect(recalculate).toHaveBeenCalledWith({ accountId: '001000000000001AAA' });
    expect(toastHandler).toHaveBeenCalledTimes(1);
    expect(getAtRiskAccounts).toHaveBeenCalledTimes(2);
  });

  it('surfaces a friendly message when the recalculate action fails', async () => {
    resolveAllWith();
    recalculate.mockRejectedValue({ body: { message: 'You do not have permission to recalculate.' } });
    const element = await createDashboard();
    const toastHandler = jest.fn();
    element.addEventListener('lightning__showtoast', toastHandler);

    element.shadowRoot.querySelector('button[data-id="001000000000001AAA"]').click();
    await flushPromises();
    await flushPromises();

    const toast = toastHandler.mock.calls[0][0];
    expect(toast.detail.variant).toBe('error');
    expect(toast.detail.message).toBe('You do not have permission to recalculate.');
  });

  it('renders a friendly empty state and clears the filters', async () => {
    resolveAllWith({ rows: [], rowCount: 0 });
    const element = await createDashboard();

    expect(element.shadowRoot.querySelector('.riq-empty').textContent).toContain('No customers match these filters');
    expect(element.shadowRoot.querySelector('tbody')).toBeNull();

    buttonByLabel(element, 'Clear filters').click();
    await flushPromises();

    const lastCall = getAtRiskAccounts.mock.calls[getAtRiskAccounts.mock.calls.length - 1][0];
    expect(lastCall.statusFilter).toBe('All');
    expect(lastCall.ownerId).toBeNull();
  });

  it('shows the server message when loading fails, and retries', async () => {
    resolveAllWith();
    getKpis.mockRejectedValueOnce({ body: { message: 'Something broke on the server.' } });
    const element = await createDashboard();

    const alert = element.shadowRoot.querySelector('[role="alert"]');
    expect(alert.textContent).toContain('We could not load the dashboard.');
    expect(alert.textContent).toContain('Something broke on the server.');

    buttonByLabel(element, 'Try again').click();
    await flushPromises();
    await flushPromises();

    expect(element.shadowRoot.querySelector('[role="alert"]')).toBeNull();
    expect(element.shadowRoot.querySelector('tbody tr')).not.toBeNull();
  });

  it('falls back to the SVG donut when Chart.js cannot load', async () => {
    resolveAllWith();
    const element = await createDashboard();

    expect(loadScript).toHaveBeenCalled();
    const fallback = element.shadowRoot.querySelector('svg.riq-donut-fallback');
    expect(fallback).not.toBeNull();
    expect(element.shadowRoot.querySelectorAll('circle.riq-donut-segment').length).toBe(4);
    expect(element.shadowRoot.querySelector('canvas.riq-donut')).toBeNull();
  });

  it('lists the status legend with shares of the total', async () => {
    resolveAllWith();
    const element = await createDashboard();

    const items = element.shadowRoot.querySelectorAll('.riq-legend__item');
    expect(items).toHaveLength(4);
    expect(items[0].textContent).toContain('Critical');
    expect(items[0].textContent).toContain('25%');
  });
});
