import { NextResponse } from 'next/server';

/**
 * Mock API for fetching yield curve / discount factors
 * 
 * The yield curve is used to discount future cash flows to present value
 * Returns zero-coupon rates and discount factors for various tenors
 */

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const index = searchParams.get('index') || 'SOFR';
  const currency = searchParams.get('currency') || 'USD';

  // Generate mock yield curve data
  const baseRate = 4.56; // Base rate around 4.56%
  const curveData = generateYieldCurve(baseRate);

  const response = {
    success: true,
    data: {
      index,
      currency,
      curve: curveData,
      // Discount factors at key points
      discountFactors: {
        "1M": calculateDiscountFactor(baseRate, 1/12),
        "3M": calculateDiscountFactor(baseRate, 0.25),
        "6M": calculateDiscountFactor(baseRate, 0.5),
        "1Y": calculateDiscountFactor(baseRate, 1),
        "2Y": calculateDiscountFactor(baseRate, 2),
        "5Y": calculateDiscountFactor(baseRate, 5),
        "10Y": calculateDiscountFactor(baseRate, 10),
        "20Y": calculateDiscountFactor(baseRate, 20),
        "30Y": calculateDiscountFactor(baseRate, 30),
      },
      // Forward rates (1-day forward starting from now)
      forwardRates: {
        "1D": baseRate + 0.01,
        "1W": baseRate + 0.03,
        "1M": baseRate + 0.08,
        "3M": baseRate + 0.18,
        "6M": baseRate + 0.32,
        "1Y": baseRate + 0.50,
      },
      // Market data metadata
      curveMetadata: {
        constructionMethod: "BOOTSTRAP",
        interpolationMethod: "LINEAR",
        compoundingFrequency: "CONTINUOUS",
        dayCountConvention: "ACT/360",
        baseDate: new Date().toISOString().split('T')[0],
        settlementDate: new Date(Date.now() + 2 * 24 * 60 * 60 * 1000).toISOString().split('T')[0],
      },
    },
    meta: {
      version: "1.0.0",
      provider: "ClearRate Yield Curve Oracle",
      source: "Chainlink CRE DON",
      calculatedAt: new Date().toISOString(),
      disclaimer: "Mock API - Do not use for production",
    }
  };

  return NextResponse.json(response);
}

// POST endpoint for batch discount factor lookup
export async function POST(request: Request) {
  try {
    const body = await request.json();
    const { tenors, index = 'SOFR' } = body;

    if (!tenors || !Array.isArray(tenors)) {
      return NextResponse.json(
        {
          success: false,
          error: "Missing required field: tenors (array of tenor strings)",
        },
        { status: 400 }
      );
    }

    const baseRate = 4.56;
    const discountFactors: Record<string, number> = {};

    tenors.forEach((tenor: string) => {
      const years = parseTenor(tenor);
      if (years !== null) {
        discountFactors[tenor] = calculateDiscountFactor(baseRate, years);
      }
    });

    const response = {
      success: true,
      data: {
        index,
        discountFactors,
        calculatedAt: new Date().toISOString(),
      },
      meta: {
        version: "1.0.0",
        disclaimer: "Mock API - Do not use for production",
      }
    };

    return NextResponse.json(response);
  } catch (error) {
    return NextResponse.json(
      {
        success: false,
        error: "Invalid request body",
        details: error instanceof Error ? error.message : "Unknown error",
      },
      { status: 400 }
    );
  }
}

function generateYieldCurve(baseRate: number) {
  const tenors = [
    { key: "1D", years: 1/365, label: "1 Day" },
    { key: "1W", years: 1/52, label: "1 Week" },
    { key: "2W", years: 2/52, label: "2 Weeks" },
    { key: "3W", years: 3/52, label: "3 Weeks" },
    { key: "1M", years: 1/12, label: "1 Month" },
    { key: "2M", years: 2/12, label: "2 Months" },
    { key: "3M", years: 3/12, label: "3 Months" },
    { key: "4M", years: 4/12, label: "4 Months" },
    { key: "5M", years: 5/12, label: "5 Months" },
    { key: "6M", years: 6/12, label: "6 Months" },
    { key: "9M", years: 9/12, label: "9 Months" },
    { key: "1Y", years: 1, label: "1 Year" },
    { key: "2Y", years: 2, label: "2 Years" },
    { key: "3Y", years: 3, label: "3 Years" },
    { key: "4Y", years: 4, label: "4 Years" },
    { key: "5Y", years: 5, label: "5 Years" },
    { key: "7Y", years: 7, label: "7 Years" },
    { key: "10Y", years: 10, label: "10 Years" },
    { key: "15Y", years: 15, label: "15 Years" },
    { key: "20Y", years: 20, label: "20 Years" },
    { key: "30Y", years: 30, label: "30 Years" },
  ];

  return tenors.map(({ key, years, label }) => {
    // Generate realistic upward-sloping curve
    const rate = baseRate + (years * 0.05) + (Math.random() * 0.1 - 0.05);
    const df = calculateDiscountFactor(baseRate, years);

    return {
      tenor: key,
      label,
      years,
      zeroCouponRate: Math.round(rate * 10000) / 10000,
      discountFactor: Math.round(df * 100000) / 100000,
      compoundedRate: Math.round((Math.exp(rate / 100) - 1) * 10000) / 10000,
    };
  });
}

function calculateDiscountFactor(baseRate: number, years: number): number {
  // Simple discount factor: DF = 1 / (1 + r)^t
  // Using continuous compounding: DF = e^(-r*t)
  return Math.exp(-(baseRate / 100) * years);
}

function parseTenor(tenor: string): number | null {
  const match = tenor.match(/^(\d+)([DWMY])$/);
  if (!match) return null;

  const value = parseInt(match[1], 10);
  const unit = match[2];

  switch (unit) {
    case 'D': return value / 365;
    case 'W': return value / 52;
    case 'M': return value / 12;
    case 'Y': return value;
    default: return null;
  }
}

export const runtime = 'edge';
