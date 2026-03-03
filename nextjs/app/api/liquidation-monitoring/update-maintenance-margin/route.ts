import { NextRequest, NextResponse } from 'next/server';
import { sql } from '@/lib/db';

/**
 * Update Maintenance Margin API
 * 
 * This endpoint updates the maintenance margin for an account's liquidation monitoring record.
 * 
 * POST /api/liquidation-monitoring/update-maintenance-margin
 * Request body:
 * {
 *   accountId: string,        // bytes32 account ID (required)
 *   maintenanceMargin: string // New maintenance margin requirement as string (uint256)
 *   collateralToken: string   // Collateral token address (optional, for multi-token accounts)
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
    
    const { accountId, maintenanceMargin, collateralToken } = body;
    
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
    
    // Validate maintenanceMargin (must be non-negative integer string)
    if (maintenanceMargin === undefined || maintenanceMargin === null) {
      return NextResponse.json(
        { success: false, message: 'Missing required field: maintenanceMargin' },
        { status: 400 }
      );
    }
    if (!/^\d+$/.test(maintenanceMargin)) {
      return NextResponse.json(
        { success: false, message: 'Invalid maintenanceMargin format - must be non-negative integer string' },
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
    
    // Check if record exists for this account (with optional collateralToken filter)
    let existingRecord;
    if (collateralToken) {
      existingRecord = await sql`
        SELECT id FROM liquidation_monitoring 
        WHERE account_id = ${accountId} AND collateral_token = ${collateralToken}
      `;
    } else {
      existingRecord = await sql`
        SELECT id FROM liquidation_monitoring WHERE account_id = ${accountId}
      `;
    }
    
    if (existingRecord.length === 0) {
      return NextResponse.json(
        { success: false, message: 'No liquidation monitoring record found for this account' },
        { status: 404 }
      );
    }
    
    // Update maintenance margin (with optional collateralToken filter)
    if (collateralToken) {
      await sql`
        UPDATE liquidation_monitoring
        SET maintenance_margin = ${maintenanceMargin}, updated_at = NOW()
        WHERE account_id = ${accountId} AND collateral_token = ${collateralToken}
      `;
    } else {
      await sql`
        UPDATE liquidation_monitoring
        SET maintenance_margin = ${maintenanceMargin}, updated_at = NOW()
        WHERE account_id = ${accountId}
      `;
    }
    
    console.log('[Liquidation Monitoring] Maintenance margin updated successfully:');
    console.log('  Account ID:', accountId);
    console.log('  Collateral Token:', collateralToken || 'all');
    console.log('  New Maintenance Margin:', maintenanceMargin);
    
    return NextResponse.json({
      success: true,
      message: 'Maintenance margin updated successfully'
    });
    
  } catch (error) {
    console.error('[Liquidation Monitoring] Error updating maintenance margin:', error);
    return NextResponse.json(
      { success: false, message: 'Internal server error' },
      { status: 500 }
    );
  }
}