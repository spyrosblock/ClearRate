import { NextResponse } from 'next/server';

/**
 * Mock API for submitting matched IRS trades to the clearinghouse
 * 
 * This endpoint simulates the novation process where the CCP becomes
 * counterparty to both sides of the trade
 * 
 * Input: Matched trade details (parties, terms, signatures)
 * Output: Trade ID, position tokens, margin requirements
 */

// In-memory trade store (would be database in production)
const trades = new Map<string, TradeRecord>();

interface TradeRecord {
  tradeId: string;
  accountId: string;
  counterpartyId: string;
  notional: number;
  fixedRate: number;
  tenor: number;
  startDate: string;
  maturityDate: string;
  direction: string;
  currency: string;
  index: string;
  status: "PENDING" | "NOVATED" | "SETTLED" | "CANCELLED";
  initialMargin: number;
  variationMargin: number;
  positionTokenId: string;
  createdAt: string;
  novatedAt?: string;
}

export async function POST(request: Request) {
  try {
    const body = await request.json();
    
    const {
      accountId,
      counterpartyId,
      notional,
      fixedRate,
      tenor,
      startDate,
      maturityDate,
      direction,
      currency = "USD",
      index = "SOFR",
      signatures,
    } = body;

    // Validate required fields
    if (!accountId || !counterpartyId || !notional || !fixedRate || !tenor || !startDate || !maturityDate || !direction) {
      return NextResponse.json(
        {
          success: false,
          error: "Missing required fields",
        },
        { status: 400 }
      );
    }

    // Validate direction
    if (direction !== "PAY_FIXED" && direction !== "RECEIVE_FIXED") {
      return NextResponse.json(
        {
          success: false,
          error: "Invalid direction. Must be PAY_FIXED or RECEIVE_FIXED",
        },
        { status: 400 }
      );
    }

    // Generate trade ID
    const tradeId = generateTradeId();
    
    // Calculate initial margin (would call IM API in production)
    const initialMargin = calculateMockIM(notional, tenor);
    
    // Generate position token ID (ERC-1155 token)
    const positionTokenId = generatePositionTokenId(tradeId);

    // Create trade record
    const trade: TradeRecord = {
      tradeId,
      accountId,
      counterpartyId,
      notional: Number(notional),
      fixedRate: Number(fixedRate),
      tenor: Number(tenor),
      startDate,
      maturityDate,
      direction,
      currency,
      index,
      status: "PENDING",
      initialMargin,
      variationMargin: 0,
      positionTokenId,
      createdAt: new Date().toISOString(),
    };

    // Store trade
    trades.set(tradeId, trade);

    // Simulate novation process
    const novatedTrade = simulateNovation(trade);

    const response = {
      success: true,
      data: {
        // Trade details
        trade: {
          tradeId: novatedTrade.tradeId,
          accountId: novatedTrade.accountId,
          counterpartyId: novatedTrade.counterpartyId,
          status: novatedTrade.status,
          createdAt: novatedTrade.createdAt,
          novatedAt: novatedTrade.novatedAt,
        },
        // Swap terms
        terms: {
          notional: novatedTrade.notional,
          fixedRateBps: novatedTrade.fixedRate,
          fixedRatePercent: (novatedTrade.fixedRate / 100).toFixed(2) + "%",
          tenorYears: novatedTrade.tenor,
          startDate: novatedTrade.startDate,
          maturityDate: novatedTrade.maturityDate,
          direction: novatedTrade.direction,
          currency: novatedTrade.currency,
          index: novatedTrade.index,
          dayCount: "ACT/360",
          paymentFrequency: "QUARTERLY",
        },
        // Position token (ERC-1155)
        position: {
          tokenId: novatedTrade.positionTokenId,
          tokenType: "IRS_POSITION",
          // Token metadata
          metadata: {
            notional: novatedTrade.notional,
            fixedRate: novatedTrade.fixedRate,
            tenor: novatedTrade.tenor,
            index: novatedTrade.index,
            direction: novatedTrade.direction,
            maturityDate: novatedTrade.maturityDate,
          },
        },
        // Margin requirements
        margin: {
          initialMargin: novatedTrade.initialMargin,
          variationMargin: novatedTrade.variationMargin,
          totalRequired: novatedTrade.initialMargin + novatedTrade.variationMargin,
          currency: novatedTrade.currency,
          settlement: "T+1",
        },
        // CCP details
        clearinghouse: {
          name: "ClearRate CCP",
          role: "CENTRAL_COUNTERPARTY",
          // Two new contracts after novation
          novatedContracts: [
            {
              party: novatedTrade.accountId,
              counterparty: "CLEARING_HOUSE",
              positionTokenId: novatedTrade.positionTokenId,
            },
            {
              party: "CLEARING_HOUSE",
              counterparty: novatedTrade.counterpartyId,
              positionTokenId: generatePositionTokenId(tradeId + "_CP"),
            },
          ],
        },
        // Validation status
        validation: {
          signaturesValid: true,
          marginSufficient: true,
          eligibleCounterparty: true,
          tradeValid: true,
        },
      },
      meta: {
        version: "1.0.0",
        calculatedAt: new Date().toISOString(),
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

// GET endpoint to retrieve trade status
export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const tradeId = searchParams.get('tradeId');
  const accountId = searchParams.get('accountId');

  if (!tradeId && !accountId) {
    return NextResponse.json(
      {
        success: false,
        error: "Missing required query parameter: tradeId or accountId",
      },
      { status: 400 }
    );
  }

  if (tradeId) {
    const trade = trades.get(tradeId);
    if (!trade) {
      return NextResponse.json(
        {
          success: false,
          error: "Trade not found",
        },
        { status: 404 }
      );
    }
    return NextResponse.json({
      success: true,
      data: trade,
    });
  }

  // Return all trades for an account
  const accountTrades = Array.from(trades.values()).filter(t => t.accountId === accountId);
  return NextResponse.json({
    success: true,
    data: {
      accountId,
      trades: accountTrades,
      count: accountTrades.length,
    },
  });
}

function generateTradeId(): string {
  const timestamp = Date.now().toString(36);
  const random = Math.random().toString(36).substring(2, 10);
  return `TRD-${timestamp}-${random}`.toUpperCase();
}

function generatePositionTokenId(tradeId: string): string {
  // Generate a unique position token ID
  const hash = tradeId.split('').reduce((acc, char) => {
    return ((acc << 5) - acc) + char.charCodeAt(0);
  }, 0);
  return Math.abs(hash).toString(16).padStart(64, '0');
}

function calculateMockIM(notional: number, tenor: number): number {
  const riskWeights: Record<number, number> = {
    1: 0.5,
    2: 1.0,
    5: 2.5,
    10: 4.0,
    20: 6.5,
    30: 8.0,
  };
  
  const tenorNum = Number(tenor);
  const riskWeight = riskWeights[tenorNum] || (tenorNum * 0.25);
  
  return Math.ceil(notional * (riskWeight / 100) * 100) / 100;
}

function simulateNovation(trade: TradeRecord): TradeRecord {
  // Simulate processing delay and novation
  return {
    ...trade,
    status: "NOVATED",
    novatedAt: new Date().toISOString(),
  };
}

export const runtime = 'edge';
