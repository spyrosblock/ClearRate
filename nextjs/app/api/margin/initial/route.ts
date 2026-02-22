import { NextResponse } from 'next/server';

/**
 * Mock API for calculating Initial Margin (IM)
 * 
 * Initial Margin covers potential future exposure based on:
 * - Notional amount
 * - Tenor (time to maturity)
 * - Volatility (historical)
 * - Confidence interval (99%)
 * 
 * Uses PAIRS methodology - 99% confidence, 5-day holding period
 */

export async function POST(request: Request) {
  try {
    const body = await request.json();
    
    const {
      accountId,
      notional,
      tenor, // in years (e.g., 1, 2, 5, 10, 30)
      currency = "USD",
      index = "SOFR",
      direction = "PAY_FIXED", // or "RECEIVE_FIXED"
    } = body;

    // Validate required fields
    if (!accountId || !notional || !tenor) {
      return NextResponse.json(
        {
          success: false,
          error: "Missing required fields: accountId, notional, tenor",
        },
        { status: 400 }
      );
    }

    // Risk weights by tenor (percentage of notional)
    const riskWeights: Record<number, number> = {
      1: 0.5,   // 1Y: 0.5%
      2: 1.0,   // 2Y: 1.0%
      5: 2.5,   // 5Y: 2.5%
      10: 4.0,  // 10Y: 4.0%
      20: 6.5,  // 20Y: 6.5%
      30: 8.0,  // 30Y: 8.0%
    };

    // Get risk weight for tenor (fallback to linear interpolation)
    const tenorNum = Number(tenor);
    const riskWeight = riskWeights[tenorNum] || (tenorNum * 0.25);

    // Apply volatility multiplier based on market conditions
    const volatilityMultiplier = 1.0 + (Math.random() * 0.2 - 0.1); // ±10%
    
    // Calculate Initial Margin
    const initialMargin = notional * (riskWeight / 100) * volatilityMultiplier;

    // Calculate VaR components for transparency
    const var99 = notional * (riskWeight / 100); // 99% VaR
    const var999 = var99 * 1.5; // 99.9% VaR (tail risk)
    const theoreticalExposure = notional * 0.15; // Maximum theoretical exposure

    const response = {
      success: true,
      data: {
        accountId,
        calculation: {
          notional: Number(notional),
          tenor: tenorNum,
          currency,
          index,
          direction,
          // Input parameters
          parameters: {
            confidenceLevel: 0.99,
            holdingPeriod: 5, // days
            volatilityLookback: 255, // trading days (1 year)
            methodology: "PAIRS",
          },
          // Calculated values
          initialMargin: Math.ceil(initialMargin * 100) / 100,
          riskWeight: riskWeight,
          riskWeightPercent: `${riskWeight.toFixed(2)}%`,
          volatility: (volatilityMultiplier - 1) * 100,
          // VaR breakdown
          var99: Math.ceil(var99 * 100) / 100,
          var999: Math.ceil(var999 * 100) / 100,
          theoreticalExposure: Math.ceil(theoreticalExposure * 100) / 100,
        },
        // Margin breakdown
        breakdown: {
          im: Math.ceil(initialMargin * 100) / 100,
          currency: "USD",
          settlement: "T+1",
        },
        // Timestamps
        calculatedAt: new Date().toISOString(),
        validUntil: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
      },
      meta: {
        version: "1.0.0",
        provider: "ClearRate Risk Engine",
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

export const runtime = 'edge';
