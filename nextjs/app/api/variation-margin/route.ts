import { NextResponse } from 'next/server';

/**
 * Position data structure received from the workflow.
 * This represents the NovatedPosition struct from the ClearingHouse contract.
 */
interface PositionData {
  tradeId: string;
  tokenIdA: string;
  tokenIdB: string;
  partyA: string;
  partyB: string;
  notional: string;
  originalNotional: string;
  fixedRateBps: string;
  startDate: string;
  maturityDate: string;
  active: boolean;
  lastNpv: string;
}

/**
 * Request body expected from the workflow when reading positions from blockchain.
 */
interface PositionsRequest {
  positions: PositionData[];
}

/**
 * Settlement entry to be returned to the workflow.
 */
interface Settlement {
  tradeId: string;
  npvChange: string;
  isFinal: boolean;
}

/**
 * POST /api/margin/variation-margin
 * 
 * Receives positions data from the workflow and calculates variation margin settlements.
 * 
 * Request body:
 * - positions: Array of position data read from the blockchain
 * 
 * Response structure:
 * - settlements: Array of VM settlement entries with tradeId, npvChange, isFinal
 * - metadata: Settlement metadata including date and NPV source
 */
export async function POST(request: Request) {
  try {
    const body: PositionsRequest = await request.json();
    
    const { positions } = body;
    
    if (!positions || !Array.isArray(positions) || positions.length === 0) {
      return NextResponse.json(
        { error: 'No positions provided' },
        { status: 400 }
      );
    }

    // Calculate settlements for each position
    // For now, we simulate NPV calculation - in production, this would call a pricing oracle
    const settlements: Settlement[] = positions
      .filter((pos) => pos.active) // Only process active positions
      .map((pos) => {
        // Calculate simulated NPV change based on position data
        // In production, this would use actual pricing data from an oracle
        const notional = BigInt(pos.notional);
        const fixedRateBps = BigInt(pos.fixedRateBps);
        
        // Simulate NPV change calculation:
        // - Use notional and fixed rate to simulate a daily VM change
        // - This is a placeholder - real implementation would use yield curve oracle
        const daysInYear = BigInt(365);
        const dailyRate = (notional * fixedRateBps) / (daysInYear * BigInt(10000));
        
        // Add some variation based on position to make it realistic
        const tradeIdHash = BigInt(pos.tradeId.slice(2, 18)) % BigInt(1000000);
        const npvChange = dailyRate + (tradeIdHash % BigInt(1000)) - BigInt(500);
        
        // Determine if position is matured (for demonstration, positions with maturity < now would be final)
        // In production, you'd check actual timestamps
        const isFinal = false; // Regular VM settlement
        
        return {
          tradeId: pos.tradeId,
          npvChange: npvChange.toString(),
          isFinal,
        };
      });

    const response = {
      settlements,
      metadata: {
        settlementDate: new Date().toISOString().split('T')[0],
        npvSource: 'internal',
        positionsCount: positions.length,
        activePositionsCount: settlements.length,
      },
    };

    return NextResponse.json(response);
  } catch (error) {
    console.error('Error processing variation margin request:', error);
    return NextResponse.json(
      { error: 'Failed to process positions' },
      { status: 500 }
    );
  }
}
