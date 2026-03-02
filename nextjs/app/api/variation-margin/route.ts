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
    const settlements: Settlement[] = positions
      .filter((pos) => pos.active) // Only process active positions
      .map((pos) => {
        const npvChange = 10000e18;  // 10k
        
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
