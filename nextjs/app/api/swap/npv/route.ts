import { NextResponse } from 'next/server';

/**
 * Mock API for calculating Net Present Value (NPV) of an Interest Rate Swap
 * 
 * NPV = PV(Floating Leg) - PV(Fixed Leg)
 * 
 * Input: Swap terms (notional, fixed rate, tenor, dates)
 * Output: NPV in USD, plus breakdown of fixed and floating leg PVs
 */

export async function POST(request: Request) {
  try {
    const body = await request.json();
    
    const {
      tradeId,
      accountId,
      notional,
      fixedRate,       // Fixed rate in bps (e.g., 450 = 4.50%)
      tenor,           // in years
      startDate,       // ISO date string
      maturityDate,    // ISO date string
      direction = "PAY_FIXED", // or "RECEIVE_FIXED"
      dayCount = "ACT/360",
      currency = "USD",
    } = body;

    // Validate required fields
    if (!accountId || !notional || !fixedRate || !tenor || !startDate || !maturityDate) {
      return NextResponse.json(
        {
          success: false,
          error: "Missing required fields: tradeId, accountId, notional, fixedRate, tenor, startDate, maturityDate",
        },
        { status: 400 }
      );
    }

    // Parse dates
    const start = new Date(startDate);
    const maturity = new Date(maturityDate);
    const today = new Date();
    
    // Calculate time-related values
    const yearsToMaturity = (maturity.getTime() - today.getTime()) / (365.25 * 24 * 60 * 60 * 1000);
    const yearsFromStart = (today.getTime() - start.getTime()) / (365.25 * 24 * 60 * 60 * 1000);
    
    // Mock market data (would come from yield curve)
    const baseRate = 4.56; // Current SOFR
    const rateCurve = generateMockCurve(yearsToMaturity);
    
    // Fixed leg calculation (simplified)
    // PV_fixed = sum of discounted fixed payments
    const fixedRateDecimal = fixedRate / 10000; // bps to decimal
    const paymentFrequency = 4; // Quarterly
    const totalPayments = Math.floor(tenor * paymentFrequency);
    const paymentsPerYear = paymentFrequency;
    
    let pvFixedLeg = 0;
    const fixedLegPayments: Array<{period: number, date: string, amount: number, discountFactor: number, pv: number}> = [];
    
    for (let i = 0; i < totalPayments; i++) {
      const paymentTime = (i + 1) / paymentsPerYear;
      const df = 1 / Math.pow(1 + baseRate / 100, paymentTime);
      const paymentAmount = notional * fixedRateDecimal / paymentsPerYear;
      const pv = paymentAmount * df;
      pvFixedLeg += pv;
      
      const paymentDate = new Date(today.getTime() + paymentTime * 365.25 * 24 * 60 * 60 * 1000);
      fixedLegPayments.push({
        period: i + 1,
        date: paymentDate.toISOString().split('T')[0],
        amount: Math.round(paymentAmount * 100) / 100,
        discountFactor: Math.round(df * 10000) / 10000,
        pv: Math.round(pv * 100) / 100,
      });
    }
    
    // Floating leg calculation (simplified)
    // PV_float = sum of discounted expected floating payments
    let pvFloatingLeg = 0;
    const floatingLegPayments: Array<{period: number, date: string, expectedRate: number, amount: number, discountFactor: number, pv: number}> = [];
    
    for (let i = 0; i < totalPayments; i++) {
      const paymentTime = (i + 1) / paymentsPerYear;
      const df = 1 / Math.pow(1 + baseRate / 100, paymentTime);
      // Mock forward rate (in reality would come from forward curve)
      const forwardRate = baseRate + (i * 0.02); // Slightly upward sloping
      const forwardRateDecimal = forwardRate / 100;
      const paymentAmount = notional * forwardRateDecimal / paymentsPerYear;
      const pv = paymentAmount * df;
      pvFloatingLeg += pv;
      
      const paymentDate = new Date(today.getTime() + paymentTime * 365.25 * 24 * 60 * 60 * 1000);
      floatingLegPayments.push({
        period: i + 1,
        date: paymentDate.toISOString().split('T')[0],
        expectedRate: Math.round(forwardRate * 100) / 100,
        amount: Math.round(paymentAmount * 100) / 100,
        discountFactor: Math.round(df * 10000) / 10000,
        pv: Math.round(pv * 100) / 100,
      });
    }
    
    // Calculate NPV
    const npv = direction === "PAY_FIXED" 
      ? pvFloatingLeg - pvFixedLeg 
      : pvFixedLeg - pvFloatingLeg;
    
    // Mark-to-market change (simulated)
    const mtmChange = npv * (Math.random() * 0.1 - 0.05); // ±5% change

    const response = {
      success: true,
      data: {
        tradeId,
        accountId,
        swapTerms: {
          notional: Number(notional),
          fixedRateBps: fixedRate,
          fixedRatePercent: (fixedRate / 100).toFixed(2) + "%",
          tenorYears: Number(tenor),
          startDate,
          maturityDate,
          direction,
          dayCount,
          currency,
          paymentFrequency: "QUARTERLY",
        },
        valuation: {
          // Present values
          pvFixedLeg: Math.round(pvFixedLeg * 100) / 100,
          pvFloatingLeg: Math.round(pvFloatingLeg * 100) / 100,
          // Net present value
          npv: Math.round(npv * 100) / 100,
          // MTM
          markToMarket: Math.round(npv * 100) / 100,
          mtmChange: Math.round(mtmChange * 100) / 100,
          mtmChangePercent: Math.round((mtmChange / npv) * 10000) / 100,
          // Direction interpretation
          interpretation: direction === "PAY_FIXED" 
            ? (npv > 0 ? "In the money (floating > fixed)" : "Out of the money (fixed > floating)")
            : (npv > 0 ? "In the money (fixed > floating)" : "Out of the money (floating > fixed)"),
        },
        // Sample payment schedule (first 4 periods)
        paymentSchedule: {
          fixedLeg: fixedLegPayments.slice(0, 4),
          floatingLeg: floatingLegPayments.slice(0, 4),
        },
        // Market data used
        marketData: {
          discountRate: baseRate,
          forwardCurve: rateCurve,
          valuationDate: today.toISOString().split('T')[0],
        },
        // Timestamps
        calculatedAt: new Date().toISOString(),
      },
      meta: {
        version: "1.0.0",
        provider: "ClearRate Valuation Engine",
        methodology: "Discounted Cash Flow",
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

// Helper function to generate mock yield curve
function generateMockCurve(yearsToMaturity: number): Record<string, number> {
  const baseRate = 4.56;
  const curve: Record<string, number> = {};
  
  const tenors = ["1M", "3M", "6M", "1Y", "2Y", "5Y", "10Y", "20Y", "30Y"];
  const tenorYears: Record<string, number> = {
    "1M": 1/12, "3M": 0.25, "6M": 0.5, "1Y": 1, "2Y": 2, 
    "5Y": 5, "10Y": 10, "20Y": 20, "30Y": 30
  };
  
  tenors.forEach(tenor => {
    const years = tenorYears[tenor];
    const rate = baseRate + (years * 0.05); // Upward sloping curve
    curve[tenor] = Math.round(rate * 100) / 100;
  });
  
  return curve;
}

export const runtime = 'edge';
