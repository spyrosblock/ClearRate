import { NextRequest, NextResponse } from 'next/server';
import { sql } from '@/lib/db';

/**
 * Update Total Collateral API
 * 
 * This endpoint updates the total collateral for an account's liquidation monitoring record.
 * 
 * POST /api/liquidation-monitoring/update-total-collateral
 * Request body:
 * {
 *   accountId: string,        // bytes32 account ID (required)
 *   totalCollateral: string   // New total collateral amount as string (uint256)
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
    
    const { accountId, totalCollateral } = body;
    
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
    
    // Validate totalCollateral (must be non-negative integer string)
    if (totalCollateral === undefined || totalCollateral === null) {
      return NextResponse.json(
        { success: false, message: 'Missing required field: totalCollateral' },
        { status: 400 }
      );
    }
    if (!/^\d+$/.test(totalCollateral)) {
      return NextResponse.json(
        { success: false, message: 'Invalid totalCollateral format - must be non-negative integer string' },
        { status: 400 }
      );
    }
    
    // Check if record exists for this account
    const existingRecord = await sql`
      SELECT id FROM liquidation_monitoring WHERE account_id = ${accountId}
    `;
    
    if (existingRecord.length === 0) {
      return NextResponse.json(
        { success: false, message: 'No liquidation monitoring record found for this account' },
        { status: 404 }
      );
    }
    
    // Update total collateral
    await sql`
      UPDATE liquidation_monitoring
      SET total_collateral = ${totalCollateral}, updated_at = NOW()
      WHERE account_id = ${accountId}
    `;
    
    console.log('[Liquidation Monitoring] Total collateral updated successfully:');
    console.log('  Account ID:', accountId);
    console.log('  New Total Collateral:', totalCollateral);
    
    return NextResponse.json({
      success: true,
      message: 'Total collateral updated successfully'
    });
    
  } catch (error) {
    console.error('[Liquidation Monitoring] Error updating total collateral:', error);
    return NextResponse.json(
      { success: false, message: 'Internal server error' },
      { status: 500 }
    );
  }
}