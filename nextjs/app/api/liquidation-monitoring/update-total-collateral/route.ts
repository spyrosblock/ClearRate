import { NextRequest, NextResponse } from 'next/server';
import { sql } from '@/lib/db';

/**
 * Update Total Collateral API
 * 
 * This endpoint updates the total collateral for an account's liquidation monitoring record.
 * It can accept either a new total collateral value or a change (npvChange) to apply.
 * 
 * POST /api/liquidation-monitoring/update-total-collateral
 * Request body:
 * {
 *   accountId: string,        // bytes32 account ID (required)
 *   totalCollateral: string,  // New total collateral amount as string (uint256) - mutually exclusive with npvChange
 *   npvChange: string,        // Change to apply to total collateral (int256, can be negative) - mutually exclusive with totalCollateral
 *   collateralToken: string   // Collateral token address (optional for backward compatibility)
 * }
 * 
 * Response:
 * {
 *   success: boolean,
 *   message?: string
 * }
 */
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    
    const { accountId, totalCollateral, npvChange, collateralToken } = body;
    
    // Validate required fields
    if (!accountId) {
      return NextResponse.json(
        { success: false, message: 'Missing required field: accountId' },
        { status: 400 }
      );
    }
    
    // Validate accountId format (bytes32 hex string)
    if (!/^0x[a-fA-F0-9]{64}$/.test(accountId)) {
      return NextResponse.json(
        { success: false, message: 'Invalid account ID format - must be bytes32 hex string (0x + 64 hex chars)' },
        { status: 400 }
      );
    }
    
    // Must provide either totalCollateral or npvChange, but not both
    const hasTotalCollateral = totalCollateral !== undefined && totalCollateral !== null;
    const hasNpvChange = npvChange !== undefined && npvChange !== null;
    
    if (!hasTotalCollateral && !hasNpvChange) {
      return NextResponse.json(
        { success: false, message: 'Must provide either totalCollateral or npvChange' },
        { status: 400 }
      );
    }
    
    if (hasTotalCollateral && hasNpvChange) {
      return NextResponse.json(
        { success: false, message: 'Cannot provide both totalCollateral and npvChange - use one or the other' },
        { status: 400 }
      );
    }
    
    // Validate totalCollateral format (must be non-negative integer string)
    if (hasTotalCollateral && !/^\d+$/.test(totalCollateral)) {
      return NextResponse.json(
        { success: false, message: 'Invalid totalCollateral format - must be non-negative integer string' },
        { status: 400 }
      );
    }
    
    // Validate npvChange format (can be negative, must be integer string)
    if (hasNpvChange && !/^-?\d+$/.test(npvChange)) {
      return NextResponse.json(
        { success: false, message: 'Invalid npvChange format - must be integer string (can be negative)' },
        { status: 400 }
      );
    }
    
    // Validate collateralToken format if provided (Ethereum address)
    if (collateralToken && !/^0x[a-fA-F0-9]{40}$/.test(collateralToken)) {
      return NextResponse.json(
        { success: false, message: 'Invalid collateral token format - must be Ethereum address' },
        { status: 400 }
      );
    }
    
    // Check if record exists for this account (+ collateralToken if provided)
    let existingRecord;
    if (collateralToken) {
      existingRecord = await sql`
        SELECT id, total_collateral FROM liquidation_monitoring 
        WHERE account_id = ${accountId} AND collateral_token = ${collateralToken}
      `;
    } else {
      existingRecord = await sql`
        SELECT id, total_collateral FROM liquidation_monitoring WHERE account_id = ${accountId}
      `;
    }
    
    if (existingRecord.length === 0) {
      return NextResponse.json(
        { success: false, message: 'No liquidation monitoring record found for this account' },
        { status: 404 }
      );
    }
    
    // Calculate the new total collateral
    let newTotalCollateral: string;
    if (hasNpvChange) {
      // Apply the change to existing collateral
      const currentCollateral = BigInt(existingRecord[0].total_collateral);
      const change = BigInt(npvChange);
      const newCollateral = currentCollateral + change;
      
      // Ensure collateral doesn't go negative
      if (newCollateral < BigInt(0)) {
        console.warn('[Liquidation Monitoring] Warning: Collateral would go negative, setting to 0');
        newTotalCollateral = '0';
      } else {
        newTotalCollateral = newCollateral.toString();
      }
    } else {
      // Use the provided totalCollateral directly
      newTotalCollateral = totalCollateral;
    }
    
    // Update total collateral
    if (collateralToken) {
      await sql`
        UPDATE liquidation_monitoring
        SET total_collateral = ${newTotalCollateral}, updated_at = NOW()
        WHERE account_id = ${accountId} AND collateral_token = ${collateralToken}
      `;
    } else {
      await sql`
        UPDATE liquidation_monitoring
        SET total_collateral = ${newTotalCollateral}, updated_at = NOW()
        WHERE account_id = ${accountId}
      `;
    }
    
    console.log('[Liquidation Monitoring] Total collateral updated successfully:');
    console.log('  Account ID:', accountId);
    console.log('  Collateral Token:', collateralToken || 'all');
    if (hasNpvChange) {
      console.log('  NPV Change:', npvChange);
    }
    console.log('  New Total Collateral:', newTotalCollateral);
    
    return NextResponse.json({
      success: true,
      message: 'Total collateral updated successfully',
      newTotalCollateral
    });
    
  } catch (error) {
    console.error('[Liquidation Monitoring] Error updating total collateral:', error);
    return NextResponse.json(
      { success: false, message: 'Internal server error' },
      { status: 500 }
    );
  }
}
