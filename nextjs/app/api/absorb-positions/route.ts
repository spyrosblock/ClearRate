import { NextResponse } from 'next/server';
import { sql } from '@/lib/db';

/**
 * Request body for absorb-positions API.
 */
interface AbsorbPositionsRequest {
  liquidatorId: string;      // bytes32 account ID of the liquidator
  liquidatedId: string;      // bytes32 account ID of the liquidated party
  collateralToken: string;   // Collateral token address (0x...)
  liquidatedTransfer: string; // Net amount to transfer from liquidated to liquidator (int256 as string)
}

/**
 * POST /api/absorb-positions
 * 
 * Absorbs positions from a liquidated party to a liquidator for a specific collateral token.
 * - Updates owner_id in active positions of swap_positions table
 * - Transfers collateral from liquidated account to liquidator in liquidation_monitoring table
 * 
 * Request body:
 * - liquidatedId: bytes32 account ID of the liquidated party (owner_id in swap_positions)
 * - collateralToken: Collateral token address to filter positions
 * - liquidatorId: bytes32 account ID of the liquidator
 * - liquidatedTransfer: Net collateral change for the liquidated account (positive = liquidated gains collateral, negative = liquidated loses collateral)
 * 
 * Response structure:
 * - success: boolean indicating operation success
 * - positionsCount: number of positions updated
 * - collateralTransferred: amount of collateral transferred
 */
export async function POST(request: Request) {
  try {
    const body: AbsorbPositionsRequest = await request.json();
    
    const { liquidatedId, collateralToken, liquidatorId, liquidatedTransfer } = body;
    
    // Validate required fields
    if (!liquidatedId || !collateralToken || !liquidatorId || liquidatedTransfer === undefined) {
      return NextResponse.json(
        { error: 'Missing required fields: liquidatedId, collateralToken, liquidatorId, and liquidatedTransfer are required' },
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

    // Parse the liquidatedTransfer amount (int256 as string)
    const transferAmount = BigInt(liquidatedTransfer);
    const zero = BigInt(0);

    // Execute both updates in a transaction
    await sql`BEGIN`;

    try {
      // Update all active positions in a single query
      const positionsResult = await sql`
        UPDATE swap_positions
        SET owner_id = ${liquidatorId}, updated_at = NOW()
        WHERE active = TRUE 
          AND collateral_token = ${collateralToken}
          AND owner_id = ${liquidatedId}
        RETURNING 1
      `;

      // Transfer collateral between accounts in liquidation_monitoring
      // liquidatedTransfer > 0: liquidated account GAINS collateral (credit), liquidator LOSES
      // liquidatedTransfer < 0: liquidated account LOSES collateral (debit), liquidator GAINS
      // This matches the on-chain behavior in MarginVault.settleVariationMargin:
      //   Positive amount = credit (account gains), negative = debit (account loses)
      if (transferAmount !== zero) {
        // Convert to numeric for database (handle both positive and negative)
        const transferNumeric = transferAmount > zero 
          ? transferAmount.toString() 
          : (-transferAmount).toString();

        if (transferAmount > zero) {
          // Positive transfer: ADD to liquidated account, DEDUCT from liquidator
          // Liquidated account gains collateral
          await sql`
            INSERT INTO liquidation_monitoring (account_id, total_collateral, maintenance_margin, collateral_token)
            VALUES (${liquidatedId}, ${transferNumeric}::numeric, 0, ${collateralToken})
            ON CONFLICT (account_id, collateral_token) 
            DO UPDATE SET 
              total_collateral = liquidation_monitoring.total_collateral + ${transferNumeric}::numeric,
              updated_at = NOW()
          `;

          // Deduct from liquidator account
          await sql`
            UPDATE liquidation_monitoring
            SET total_collateral = GREATEST(total_collateral - ${transferNumeric}::numeric, 0),
                updated_at = NOW()
            WHERE account_id = ${liquidatorId}
              AND collateral_token = ${collateralToken}
          `;
        } else {
          // Negative transfer: DEDUCT from liquidated account, ADD to liquidator
          // Liquidated account loses collateral
          await sql`
            UPDATE liquidation_monitoring
            SET total_collateral = GREATEST(total_collateral - ${transferNumeric}::numeric, 0),
                updated_at = NOW()
            WHERE account_id = ${liquidatedId}
              AND collateral_token = ${collateralToken}
          `;

          // Add to liquidator account
          await sql`
            INSERT INTO liquidation_monitoring (account_id, total_collateral, maintenance_margin, collateral_token)
            VALUES (${liquidatorId}, ${transferNumeric}::numeric, 0, ${collateralToken})
            ON CONFLICT (account_id, collateral_token) 
            DO UPDATE SET 
              total_collateral = liquidation_monitoring.total_collateral + ${transferNumeric}::numeric,
              updated_at = NOW()
          `;
        }
      }

      await sql`COMMIT`;

      const response = {
        success: true,
        positionsCount: positionsResult.length,
        collateralTransferred: liquidatedTransfer,
        metadata: {
          liquidatorId,
          liquidatedId,
          collateralToken,
          timestamp: new Date().toISOString(),
        },
      };

      return NextResponse.json(response);
    } catch (txError) {
      await sql`ROLLBACK`;
      throw txError;
    }
  } catch (error) {
    console.error('Error processing absorb-positions request:', error);
    
    return NextResponse.json(
      { error: 'Failed to process absorb-positions request' },
      { status: 500 }
    );
  }
}
