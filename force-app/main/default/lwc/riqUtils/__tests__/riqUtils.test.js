import {
  buildDonutSegments,
  buildSparklinePoints,
  daysLabel,
  formatCompactCurrency,
  formatCurrency,
  formatPercent,
  gaugeDashArray,
  scoreLabel,
  statusColor,
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
  });

  it('maps statuses to their chart colours', () => {
    expect(statusColor('Critical')).toBe('#ba0517');
    expect(statusColor('Healthy')).toBe('#2e844a');
  });
});

describe('riqUtils formatting', () => {
  it('formats whole-dollar currency', () => {
    expect(formatCurrency(1250000)).toBe('$1,250,000');
    expect(formatCurrency(0)).toBe('$0');
  });

  it('returns an em dash for unknown currency and percentages', () => {
    expect(formatCurrency(null)).toBe('—');
    expect(formatCurrency(undefined)).toBe('—');
    expect(formatPercent(null)).toBe('—');
    expect(formatPercent('not a number')).toBe('—');
  });

  it('compacts large amounts for KPI tiles', () => {
    expect(formatCompactCurrency(2500000000)).toBe('$2.5B');
    expect(formatCompactCurrency(1200000)).toBe('$1.2M');
    expect(formatCompactCurrency(45000)).toBe('$45K');
    expect(formatCompactCurrency(120)).toBe('$120');
    expect(formatCompactCurrency(null)).toBe('—');
  });

  it('rounds percentages', () => {
    expect(formatPercent(62.4)).toBe('62%');
    expect(formatPercent(0)).toBe('0%');
  });

  it('labels days to renewal, including overdue', () => {
    expect(daysLabel(12)).toBe('12d');
    expect(daysLabel(0)).toBe('Today');
    expect(daysLabel(-5)).toBe('5d overdue');
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
