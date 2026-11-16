/* eslint-disable @lwc/lwc/no-async-operation -- the test helper flushes a macrotask */
import { createElement } from 'lwc';
import RiqCommandCenter from 'c/riqCommandCenter';
import getKpis from '@salesforce/apex/RIQ_DashboardController.getKpis';
import getStatusDistribution from '@salesforce/apex/RIQ_DashboardController.getStatusDistribution';
import getAtRiskAccounts from '@salesforce/apex/RIQ_DashboardController.getAtRiskAccounts';
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
    daysToRenewal: 12
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

function resolveAllWith({ rows = ROWS, kpis = KPIS, slices = SLICES } = {}) {
  getKpis.mockResolvedValue(kpis);
  getStatusDistribution.mockResolvedValue(slices);
  getAtRiskAccounts.mockResolvedValue(rows);
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

  it('renders KPI tiles and the at-risk rows', async () => {
    resolveAllWith();
    const element = await createDashboard();

    const tiles = element.shadowRoot.querySelectorAll('.riq-kpi');
    expect(tiles).toHaveLength(4);
    expect(element.shadowRoot.textContent).toContain('$4.2M');
    expect(element.shadowRoot.textContent).toContain('$1.2M');

    const table = element.shadowRoot.querySelector('lightning-datatable');
    expect(table).not.toBeNull();
    expect(table.data).toHaveLength(1);
    expect(table.data[0].churnDisplay).toBe('72%');
    expect(table.data[0].arrDisplay).toBe('$480K');
    expect(table.data[0].renewalDisplay).toBe('12d');
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

  it('translates a datatable sort into a server sort', async () => {
    resolveAllWith();
    const element = await createDashboard();

    const table = element.shadowRoot.querySelector('lightning-datatable');
    table.dispatchEvent(new CustomEvent('sort', { detail: { fieldName: 'churnDisplay', sortDirection: 'asc' } }));
    await flushPromises();

    const lastCall = getAtRiskAccounts.mock.calls[getAtRiskAccounts.mock.calls.length - 1][0];
    expect(lastCall.sortBy).toBe('churn');
    expect(lastCall.sortDirection).toBe('asc');
  });

  it('recalculates a row and reloads the dashboard', async () => {
    resolveAllWith();
    recalculate.mockResolvedValue({ accountName: 'Acme', score: 44, status: 'At Risk' });
    const element = await createDashboard();
    const toastHandler = jest.fn();
    element.addEventListener('lightning__showtoast', toastHandler);

    const table = element.shadowRoot.querySelector('lightning-datatable');
    table.dispatchEvent(
      new CustomEvent('rowaction', {
        detail: {
          action: { name: 'recalculate' },
          row: { accountId: '001000000000001AAA', name: 'Acme' }
        }
      })
    );
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

    const table = element.shadowRoot.querySelector('lightning-datatable');
    table.dispatchEvent(
      new CustomEvent('rowaction', {
        detail: { action: { name: 'recalculate' }, row: { accountId: '001000000000001AAA' } }
      })
    );
    await flushPromises();
    await flushPromises();

    const toast = toastHandler.mock.calls[0][0];
    expect(toast.detail.variant).toBe('error');
    expect(toast.detail.message).toBe('You do not have permission to recalculate.');
  });

  it('renders an empty state when nothing matches the filters', async () => {
    resolveAllWith({ rows: [] });
    const element = await createDashboard();

    expect(element.shadowRoot.querySelector('.riq-empty')).not.toBeNull();
    expect(element.shadowRoot.querySelector('lightning-datatable')).toBeNull();
  });

  it('shows the server message when loading fails, and retries', async () => {
    resolveAllWith();
    getKpis.mockRejectedValueOnce({ body: { message: 'Something broke on the server.' } });
    const element = await createDashboard();

    expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toContain('Something broke on the server.');

    element.shadowRoot.querySelector('lightning-button').click();
    await flushPromises();
    await flushPromises();

    expect(element.shadowRoot.querySelector('[role="alert"]')).toBeNull();
    expect(element.shadowRoot.querySelector('lightning-datatable')).not.toBeNull();
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
