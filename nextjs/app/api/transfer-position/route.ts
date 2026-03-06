import { NextResponse } from 'next/server';
import { sql } from '@/lib/db';

/**
 * Request body for transfer-position API.
 */
interface TransferPositionRequest {
  tokenId: string;            // uint256 token ID of the position
  fromAccountId: string;      // bytes32 account ID of the sender
  toAccountId: string;        // bytes32 account ID of the recipient
  amount: string;             // Amount (notional) transferred
  collateralToken: string;    // Collateral token address (0x...)
  newMMFrom: string;          // New maintenance margin for sender
  newMMTo: string;            // New maintenance margin for recipient
}

/**
 * POST /api/transfer-position
 * 
 * Transfers a position (or partial position) from one account to another.
 * - Updates owner_id in swap_positions table
 * - Handles both full and partial transfers (via balance tracking)
 * - Updates maintenance margins for both accounts
 * 
 * Request body:
 * - tokenId: uint256 token ID of the position being transferred
 * - fromAccountId: bytes32 account ID of the sender
 * - toAccountId: bytes32 account ID of the recipient
 * - amount: Amount (notional) being transferred
 * - collateralToken: Collateral token address
 * - newMMFrom: New maintenance margin for sender
 * - newMMTo: New maintenance margin for recipient
 * 
 * Response structure:
 * - success: boolean indicating operation success
 * - message: description of the result
 */
export async function POST(request: Request) {
  try {
    const body: TransferPositionRequest = await request.json();
    
    const { tokenId, fromAccountId, toAccountId, amount, collateralToken, newMMFrom, newMMTo } = body;
    
    // Validate required fields
    if (!tokenId || !fromAccountId || !toAccountId || !amount || !collateralToken || newMMFrom === undefined || newMMTo === undefined) {
      return NextResponse.json(
        { error: 'Missing required fields: tokenId, fromAccountId, toAccountId, amount, collateralToken, newMMFrom, and newMMTo are required' },
        { status: 400 }
      );
    }

    // Validate that fromAccountId and toAccountId are different
    if (fromAccountId.toLowerCase() === toAccountId.toLowerCase()) {
      return NextResponse.json(
        { error: 'fromAccountId and toAccountId must be different' },
        { status: 400 }
      );
    }

    // Parse the transfer amount
    const transferAmount = BigInt(amount);

    if (transferAmount <= BigInt(0)) {
      return NextResponse.json(
        { error: 'Amount must be greater than 0' },
        { status: 400 }
      );
    }

    // Execute updates in a transaction
    await sql`BEGIN`;

    try {
      // Check if sender has the position
      const senderPosition = await sql`
        SELECT balance, notional FROM swap_positions
        WHERE token_id = ${tokenId} AND owner_id = ${fromAccountId} AND active = TRUE
      `;

      if (senderPosition.length === 0) {
        await sql`ROLLBACK`;
        return NextResponse.json(
          { error: `No active position found for token ${tokenId} and sender ${fromAccountId}` },
          { status: 404 }
        );
      }

      const senderBalance = BigInt(senderPosition[0].balance);
      const notional = senderPosition[0].notional;

      if (senderBalance < transferAmount) {
        await sql`ROLLBACK`;
        return NextResponse.json(
          { error: `Insufficient balance. Sender has ${senderBalance.toString()}, trying to transfer ${transferAmount.toString()}` },
          { status: 400 }
        );
      }

      const isFullTransfer = senderBalance === transferAmount;

      // Check if recipient already has a position for this token
      const recipientPosition = await sql`
        SELECT balance FROM swap_positions
        WHERE token_id = ${tokenId} AND owner_id = ${toAccountId} AND active = TRUE
      `;

      if (isFullTransfer) {
        // Full transfer: update owner_id
        if (recipientPosition.length > 0) {
          // Recipient already has a position - add to their balance
          const existingBalance = BigInt(recipientPosition[0].balance);
          const newRecipientBalance = existingBalance + transferAmount;
          
          await sql`
            UPDATE swap_positions
            SET balance = ${newRecipientBalance.toString()}, updated_at = NOW()
            WHERE token_id = ${tokenId} AND owner_id = ${toAccountId} AND active = TRUE
          `;
          
          // Remove sender's position record
          await sql`
            DELETE FROM swap_positions
            WHERE token_id = ${tokenId} AND owner_id = ${fromAccountId}
          `;
        } else {
          // Simple owner transfer
          await sql`
            UPDATE swap_positions
            SET owner_id = ${toAccountId}, updated_at = NOW()
            WHERE token_id = ${tokenId} AND owner_id = ${fromAccountId}
          `;
        }
      } else {
        // Partial transfer: update balances
        const newSenderBalance = senderBalance - transferAmount;
        
        // Update sender's balance
        await sql`
          UPDATE swap_positions
          SET balance = ${newSenderBalance.toString()}, updated_at = NOW()
          WHERE token_id = ${tokenId} AND owner_id = ${fromAccountId} AND active = TRUE
        `;
        
        // Update or create recipient's position
        if (recipientPosition.length > 0) {
          // Add to existing recipient balance
          const existingBalance = BigInt(recipientPosition[0].balance);
          const newRecipientBalance = existingBalance + transferAmount;
          
          await sql`
            UPDATE swap_positions
            SET balance = ${newRecipientBalance.toString()}, updated_at = NOW()
            WHERE token_id = ${tokenId} AND owner_id = ${toAccountId} AND active = TRUE
          `;
        } else {
          // Create new position record for recipient
          await sql`
            INSERT INTO swap_positions (
              token_id, owner_id, balance, notional, fixed_rate_bps, 
              start_date, maturity_date, payment_interval, direction,
              floating_rate_index, day_count_convention, collateral_token,
              active, last_npv
            )
            SELECT 
              token_id, ${toAccountId}, ${transferAmount.toString()}, notional, fixed_rate_bps,
              start_date, maturity_date, payment_interval, direction,
              floating_rate_index, day_count_convention, collateral_token,
              TRUE, last_npv
            FROM swap_positions
            WHERE token_id = ${tokenId} AND owner_id = ${fromAccountId} AND active = TRUE
          `;
        }
      }

      // Update maintenance margins for both accounts
      await sql`
        INSERT INTO liquidation_monitoring (account_id, total_collateral, maintenance_margin, collateral_token)
        VALUES (${fromAccountId}, 0, ${newMMFrom}::numeric, ${collateralToken})
        ON CONFLICT (account_id, collateral_token) 
        DO UPDATE SET 
          maintenance_margin = ${newMMFrom}::numeric,
          updated_at = NOW()
      `;

      await sql`
        INSERT INTO liquidation_monitoring (account_id, total_collateral, maintenance_margin, collateral_token)
        VALUES (${toAccountId}, 0, ${newMMTo}::numeric, ${collateralToken})
        ON CONFLICT (account_id, collateral_token) 
        DO UPDATE SET 
          maintenance_margin = ${newMMTo}::numeric,
          updated_at = NOW()
      `;

      await sql`COMMIT`;

      const response = {
        success: true,
        message: `Successfully transferred ${transferAmount.toString()} of token ${tokenId} from ${fromAccountId} to ${toAccountId}`,
        metadata: {
          tokenId,
          fromAccountId,
          toAccountId,
          amount: transferAmount.toString(),
          isFullTransfer,
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
    console.error('Error processing transfer-position request:', error);
    
    return NextResponse.json(
      { error: 'Failed to process transfer-position request' },
      { status: 500 }
    );
  }
}