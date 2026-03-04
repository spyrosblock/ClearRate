import { NextResponse } from 'next/server';
import { sql } from '@/lib/db';

/**
 * Request body for absorb-positions API.
 */
interface AbsorbPositionsRequest {
  liquidatorId: string;   // bytes32 account ID of the liquidator
  liquidatedId: string;    // bytes32 account ID of the liquidated party
  premium: string;         // Premium amount to transfer (uint256 as string)
  collateralToken: string; // Collateral token address (0x...)
}

/**
 * Position update result.
 */
interface PositionUpdate {
  tradeId: string;
  updatedField: 'party_a' | 'party_b';
  oldValue: string;
  newValue: string;
}

/**
 * Collateral update result.
 */
interface CollateralUpdate {
  accountId: string;
  previousCollateral: string;
  newCollateral: string;
  change: string;
}

/**
 * POST /api/absorb-positions
 * 
 * Absorbs positions from a liquidated party to a liquidator for a specific collateral token.
 * - Updates party_a or party_b in active positions of novated_positions table
 * - Updates total_collateral in liquidation_monitoring table
 * 
 * Request body:
 * - liquidatedId: bytes32 account ID of the liquidated party
 * - collateralToken: Collateral token address to filter positions and collateral
 * - liquidatorId: bytes32 account ID of the liquidator
 * - premium: Premium amount to transfer (subtracted from liquidated, added to liquidator)
 * 
 * Response structure:
 * - success: boolean indicating operation success
 * - positionsUpdated: Array of position update details
 * - collateralUpdates: Object with liquidator and liquidated collateral changes
 */
export async function POST(request: Request) {
  try {
    const body: AbsorbPositionsRequest = await request.json();
    
    const { liquidatedId, collateralToken, liquidatorId, premium } = body;
    
    // Validate required fields
    if (!liquidatedId || !collateralToken  || !liquidatorId|| !premium) {
      return NextResponse.json(
        { error: 'Missing required fields: liquidatedId, collateralToken, liquidatorId and premium are required' },
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

    // Validate premium is a valid number
    const premiumAmount = BigInt(premium);
    if (premiumAmount < 0) {
      return NextResponse.json(
        { error: 'premium must be a non-negative number' },
        { status: 400 }
      );
    }

    // Start transaction-like operations
    
    // 1. Get active positions where liquidatedId is party_a or party_b for the specific collateral token
    const activePositions = await sql`
      SELECT trade_id, party_a, party_b
      FROM novated_positions
      WHERE active = TRUE 
        AND collateral_token = ${collateralToken}
        AND (party_a = ${liquidatedId} OR party_b = ${liquidatedId})
    `;

    const positionUpdates: PositionUpdate[] = [];

    // 2. Update each active position - replace liquidatedId with liquidatorId
    for (const position of activePositions) {
      let updatedField: 'party_a' | 'party_b';
      let updateResult;

      if (position.party_a === liquidatedId) {
        // Update party_a
        updateResult = await sql`
          UPDATE novated_positions
          SET party_a = ${liquidatorId}, updated_at = NOW()
          WHERE trade_id = ${position.trade_id} AND active = TRUE
        `;
        updatedField = 'party_a';
      } else {
        // Update party_b
        updateResult = await sql`
          UPDATE novated_positions
          SET party_b = ${liquidatorId}, updated_at = NOW()
          WHERE trade_id = ${position.trade_id} AND active = TRUE
        `;
        updatedField = 'party_b';
      }

      positionUpdates.push({
        tradeId: position.trade_id,
        updatedField,
        oldValue: liquidatedId,
        newValue: liquidatorId,
      });
    }

    // 3. Get current collateral for both parties for the specific collateral token
    const liquidatorCollateral = await sql`
      SELECT account_id, total_collateral
      FROM liquidation_monitoring
      WHERE account_id = ${liquidatorId} AND collateral_token = ${collateralToken}
    `;

    const liquidatedCollateral = await sql`
      SELECT account_id, total_collateral
      FROM liquidation_monitoring
      WHERE account_id = ${liquidatedId} AND collateral_token = ${collateralToken}
    `;

    if (liquidatorCollateral.length === 0) {
      return NextResponse.json(
        { error: 'Liquidator account not found in liquidation_monitoring table for the specified collateral token' },
        { status: 404 }
      );
    }

    if (liquidatedCollateral.length === 0) {
      return NextResponse.json(
        { error: 'Liquidated account not found in liquidation_monitoring table for the specified collateral token' },
        { status: 404 }
      );
    }

    // 4. Update collateral for liquidator (add premium)
    const liquidatorPreviousCollateral = BigInt(liquidatorCollateral[0].total_collateral);
    const liquidatorNewCollateral = liquidatorPreviousCollateral + premiumAmount;

    await sql`
      UPDATE liquidation_monitoring
      SET total_collateral = ${liquidatorNewCollateral.toString()}, updated_at = NOW()
      WHERE account_id = ${liquidatorId} AND collateral_token = ${collateralToken}
    `;

    // 5. Update collateral for liquidated (subtract premium)
    const liquidatedPreviousCollateral = BigInt(liquidatedCollateral[0].total_collateral);
    const liquidatedNewCollateral = liquidatedPreviousCollateral - premiumAmount;

    // Check for insufficient collateral
    if (liquidatedNewCollateral < 0) {
      return NextResponse.json(
        { 
          error: 'Insufficient collateral for liquidated account',
          details: {
            currentCollateral: liquidatedPreviousCollateral.toString(),
            premiumRequested: premiumAmount.toString(),
            shortfall: (-liquidatedNewCollateral).toString()
          }
        },
        { status: 400 }
      );
    }

    await sql`
      UPDATE liquidation_monitoring
      SET total_collateral = ${liquidatedNewCollateral.toString()}, updated_at = NOW()
      WHERE account_id = ${liquidatedId} AND collateral_token = ${collateralToken}
    `;

    const collateralUpdates: {
      liquidator: CollateralUpdate;
      liquidated: CollateralUpdate;
    } = {
      liquidator: {
        accountId: liquidatorId,
        previousCollateral: liquidatorPreviousCollateral.toString(),
        newCollateral: liquidatorNewCollateral.toString(),
        change: `+${premiumAmount.toString()}`,
      },
      liquidated: {
        accountId: liquidatedId,
        previousCollateral: liquidatedPreviousCollateral.toString(),
        newCollateral: liquidatedNewCollateral.toString(),
        change: `-${premiumAmount.toString()}`,
      },
    };

    const response = {
      success: true,
      positionsUpdated: positionUpdates,
      positionsCount: positionUpdates.length,
      collateralUpdates,
      metadata: {
        liquidatorId,
        liquidatedId,
        premium: premiumAmount.toString(),
        collateralToken,
        timestamp: new Date().toISOString(),
      },
    };

    return NextResponse.json(response);
  } catch (error) {
    console.error('Error processing absorb-positions request:', error);
    
    // Handle BigInt conversion error
    if (error instanceof Error && error.message.includes('Cannot convert')) {
      return NextResponse.json(
        { error: 'Invalid premium value: must be a valid non-negative integer' },
        { status: 400 }
      );
    }
    
    return NextResponse.json(
      { error: 'Failed to process absorb-positions request' },
      { status: 500 }
    );
  }
}