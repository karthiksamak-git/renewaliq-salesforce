import {
  buildDonutSegments,
  buildSparklinePoints,
  daysLabel,
  formatDate,
  formatDateTime,
  formatInr,
  formatInrCompact,
  formatPercent,
  gaugeDashArray,
  scoreLabel,
  statusBadgeStyle,
  statusColor,
  statusIcon,
  statusTheme
} from 'c/riqUtils';

describe('riqUtils status mapping', () => {
  it('maps each known status to a theme', () => {
    expect(statusTheme('Critical')).toBe('error');
    expect(statusTheme('At Risk')).toBe('warning');
    expect(statusTheme('Watch')).toBe('info');
    expect(statusTheme('Healthy')).toBe('success');
  });

  it('falls back to a neutral theme and colour for unknown status', () => {
    expect(statusTheme(undefined)).toBe('inverse');
    expect(statusColor('Nonsense')).toBe('#747474');
    expect(statusIcon('Nonsense')).toBe('utility:help');
  });

  it('maps statuses to their chart colours and icons', () => {
    expect(statusColor('Critical')).toBe('#ba0517');
    expect(statusColor('Healthy')).toBe('#2e844a');
    expect(statusIcon('Critical')).toBe('utility:warning');
    expect(statusIcon('Healthy')).toBe('utility:success');
  });

  it('tints the status badge with the same colour as the donut slice', () => {
    const style = statusBadgeStyle('At Risk');

    expect(style).toContain('#fe9339');
    expect(style).toContain('border-color');
  });
});

describe('riqUtils Indian currency formatting', () => {
  it('formats full amounts with Indian digit grouping and the rupee sign', () => {
    expect(formatInr(1250000)).toBe('₹12,50,000');
    expect(formatInr(100000)).toBe('₹1,00,000');
    expect(formatInr(0)).toBe('₹0');
  });

  it('returns an em dash for unknown amounts and percentages', () => {
    expect(formatInr(null)).toBe('—');
    expect(formatInr(undefined)).toBe('—');
    expect(formatInr('')).toBe('—');
    expect(formatInr('not a number')).toBe('—');
    expect(formatPercent(null)).toBe('—');
    expect(formatPercent('not a number')).toBe('—');
  });

  it('keeps small amounts in full below one lakh', () => {
    expect(formatInrCompact(120)).toBe('₹120');
    expect(formatInrCompact(45000)).toBe('₹45,000');
    expect(formatInrCompact(99999)).toBe('₹99,999');
    expect(formatInrCompact(0)).toBe('₹0');
  });

  it('switches to lakh at exactly one lakh', () => {
    expect(formatInrCompact(100000)).toBe('₹1 L');
    expect(formatInrCompact(150000)).toBe('₹1.5 L');
    expect(formatInrCompact(1250000)).toBe('₹12.5 L');
  });

  it('switches to crore at exactly one crore', () => {
    expect(formatInrCompact(9999999)).toBe('₹99.9 L');
    expect(formatInrCompact(10000000)).toBe('₹1 Cr');
    expect(formatInrCompact(42500000)).toBe('₹4.25 Cr');
  });

  it('handles negatives without losing the sign', () => {
    expect(formatInr(-150000)).toBe('-₹1,50,000');
    expect(formatInrCompact(-150000)).toBe('-₹1.5 L');
    expect(formatInrCompact(-25000000)).toBe('-₹2.5 Cr');
    expect(formatInrCompact(null)).toBe('—');
  });

  it('rounds percentages', () => {
    expect(formatPercent(62.4)).toBe('62%');
    expect(formatPercent(0)).toBe('0%');
  });
});

describe('riqUtils dates', () => {
  it('renders a date-only value without shifting the day', () => {
    expect(formatDate('2026-12-31')).toBe('31 Dec 2026');
    expect(formatDate(null)).toBe('—');
    expect(formatDate('not a date')).toBe('—');
  });

  it('renders timestamps in IST with no raw ISO string left over', () => {
    const display = formatDateTime('2026-11-15T09:30:00.000Z');

    expect(display).toContain('2026');
    expect(display).not.toMatch(/\d{4}-\d{2}-\d{2}T/);
    expect(display).toContain('IST');
    expect(formatDateTime(null)).toBe('—');
  });

  it('labels days to renewal in plain language, including overdue', () => {
    expect(daysLabel(12)).toBe('12 days');
    expect(daysLabel(1)).toBe('1 day');
    expect(daysLabel(0)).toBe('Today');
    expect(daysLabel(-5)).toBe('5 days overdue');
    expect(daysLabel(-1)).toBe('1 day overdue');
    expect(daysLabel(null)).toBe('—');
  });

  it('describes the score accessibly', () => {
    expect(scoreLabel(73.2)).toBe('73 out of 100');
    expect(scoreLabel(null)).toBe('Not scored');
  });
});

describe('riqUtils donut geometry', () => {
  const circumference = 2 * Math.PI * 54;

  it('splits the circumference by share of total', () => {
    const segments = buildDonutSegments(
      [
        { label: 'Critical', count: 1 },
        { label: 'Healthy', count: 3 }
      ],
      54
    );

    expect(segments).toHaveLength(2);
    expect(segments[0].percentage).toBe(25);
    expect(segments[1].percentage).toBe(75);

    const [length] = segments[0].dashArray.split(' ');
    expect(Number(length)).toBeCloseTo(circumference / 4, 3);
    expect(segments[0].dashOffset).toBe(0);
    expect(segments[1].dashOffset).toBeCloseTo(-circumference / 4, 3);
  });

  it('skips empty slices and handles no data', () => {
    const segments = buildDonutSegments([
      { label: 'Critical', count: 0 },
      { label: 'Watch', count: 2 }
    ]);

    expect(segments).toHaveLength(1);
    expect(segments[0].label).toBe('Watch');
    expect(buildDonutSegments([])).toEqual([]);
    expect(buildDonutSegments(undefined)).toEqual([]);
  });

  it('exposes an inline swatch style per segment', () => {
    const [segment] = buildDonutSegments([{ label: 'Critical', count: 4 }]);

    expect(segment.swatchStyle).toBe('background-color: #ba0517');
    expect(segment.icon).toBe('utility:warning');
  });
});

describe('riqUtils sparkline geometry', () => {
  it('scales a series across the full width', () => {
    const points = buildSparklinePoints([10, 20, 30], 200, 50);

    expect(points.split(' ')).toHaveLength(3);
    expect(points).toBe('0,50 100,25 200,0');
  });

  it('handles flat series without dividing by zero', () => {
    expect(buildSparklinePoints([50, 50, 50], 200, 50)).toBe('0,50 100,50 200,50');
  });

  it('draws a flat line for a single point and nothing for no data', () => {
    expect(buildSparklinePoints([42], 200, 50)).toBe('0,25 200,25');
    expect(buildSparklinePoints([], 200, 50)).toBe('');
    expect(buildSparklinePoints(null)).toBe('');
  });
});

describe('riqUtils gauge geometry', () => {
  const circumference = 2 * Math.PI * 52;

  it('fills the ring proportionally to the score', () => {
    const [filled] = gaugeDashArray(25, 52).split(' ');
    expect(Number(filled)).toBeCloseTo(circumference / 4, 3);
  });

  it('clamps out-of-range and missing scores', () => {
    expect(gaugeDashArray(150, 52)).toBe(gaugeDashArray(100, 52));
    expect(gaugeDashArray(-20, 52)).toBe(gaugeDashArray(0, 52));
    expect(gaugeDashArray(null, 52)).toBe(gaugeDashArray(0, 52));
  });
});
