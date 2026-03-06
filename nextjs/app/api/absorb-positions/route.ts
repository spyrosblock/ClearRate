import { NextResponse } from 'next/server';
import { sql } from '@/lib/db';

/**
 * Request body for absorb-positions API.
 */
interface AbsorbPositionsRequest {
  liquidatorId: string;   // bytes32 account ID of the liquidator
  liquidatedId: string;   // bytes32 account ID of the liquidated party
  collateralToken: string; // Collateral token address (0x...)
}

/**
 * POST /api/absorb-positions
 * 
 * Absorbs positions from a liquidated party to a liquidator for a specific collateral token.
 * - Updates owner_id in active positions of swap_positions table
 * 
 * Request body:
 * - liquidatedId: bytes32 account ID of the liquidated party (owner_id in swap_positions)
 * - collateralToken: Collateral token address to filter positions
 * - liquidatorId: bytes32 account ID of the liquidator
 * 
 * Response structure:
 * - success: boolean indicating operation success
 * - positionsUpdated: Array of position update details
 */
export async function POST(request: Request) {
  try {
    const body: AbsorbPositionsRequest = await request.json();
    
    const { liquidatedId, collateralToken, liquidatorId } = body;
    
    // Validate required fields
    if (!liquidatedId || !collateralToken || !liquidatorId) {
      return NextResponse.json(
        { error: 'Missing required fields: liquidatedId, collateralToken, and liquidatorId are required' },
        { status: 400 }
      );
    }

    // Validate that liquidatorId and liquidatedId are different
    if (liquidatorId.toLowerCase() === liquidatedId.toLowerCase()) {
      return NextResponse.json(
        { error: 'liquidatorId and liquidatedId must be different' },
        { status: 400 }
      );
    }

    // Update all active positions in a single query
    const result = await sql`
      UPDATE swap_positions
      SET owner_id = ${liquidatorId}, updated_at = NOW()
      WHERE active = TRUE 
        AND collateral_token = ${collateralToken}
        AND owner_id = ${liquidatedId}
      RETURNING 1
    `;

    const response = {
      success: true,
      positionsCount: result.length,
      metadata: {
        liquidatorId,
        liquidatedId,
        collateralToken,
        timestamp: new Date().toISOString(),
      },
    };

    return NextResponse.json(response);
  } catch (error) {
    console.error('Error processing absorb-positions request:', error);
    
    return NextResponse.json(
      { error: 'Failed to process absorb-positions request' },
      { status: 500 }
    );
  }
}