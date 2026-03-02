import { NextRequest, NextResponse } from 'next/server';
import { sql } from '@/lib/db';

/**
 * Create Liquidation Monitoring Record API
 * 
 * This endpoint creates a new liquidation monitoring record for an account.
 * 
 * POST /api/liquidation-monitoring/create-record
 * Request body:
 * {
 *   accountId: string,        // bytes32 account ID (required)
 *   totalCollateral: string,  // Total collateral amount as string (uint256)
 *   maintenanceMargin: string, // Maintenance margin requirement as string (uint256)
 *   collateralToken: string   // Collateral token address (required)
 * }
 * 
 * Response:
 * {
 *   success: boolean,
 *   recordId?: number,
 *   message?: string
 * }
 */
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    
    const { accountId, totalCollateral, maintenanceMargin, collateralToken } = body;
    
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
    
    // Validate collateral token format (Ethereum address)
    if (!collateralToken) {
      return NextResponse.json(
        { success: false, message: 'Missing required field: collateralToken' },
        { status: 400 }
      );
    }
    if (!/^0x[a-fA-F0-9]{40}$/.test(collateralToken)) {
      return NextResponse.json(
        { success: false, message: 'Invalid collateral token format - must be Ethereum address' },
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
    
    // Check if record already exists for this account
    const existingRecord = await sql`
      SELECT id FROM liquidation_monitoring WHERE account_id = ${accountId}
    `;
    
    if (existingRecord.length > 0) {
      return NextResponse.json(
        { success: false, message: 'Liquidation monitoring record already exists for this account' },
        { status: 409 }
      );
    }
    
    // Insert new record
    const result = await sql`
      INSERT INTO liquidation_monitoring (
        account_id,
        total_collateral,
        maintenance_margin,
        collateral_token
      ) VALUES (
        ${accountId},
        ${totalCollateral},
        ${maintenanceMargin},
        ${collateralToken}
      )
      RETURNING id
    `;
    
    console.log('[Liquidation Monitoring] Record created successfully:');
    console.log('  Account ID:', accountId);
    console.log('  Total Collateral:', totalCollateral);
    console.log('  Maintenance Margin:', maintenanceMargin);
    console.log('  Collateral Token:', collateralToken);
    
    return NextResponse.json({
      success: true,
      recordId: result[0].id,
      message: 'Liquidation monitoring record created successfully'
    });
    
  } catch (error) {
    console.error('[Liquidation Monitoring] Error creating record:', error);
    return NextResponse.json(
      { success: false, message: 'Internal server error' },
      { status: 500 }
    );
  }
}