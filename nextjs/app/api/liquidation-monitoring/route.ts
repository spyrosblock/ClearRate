import { NextRequest, NextResponse } from 'next/server';
import { sql } from '@/lib/db';

/**
 * Get Liquidation Monitoring Record API
 * 
 * This endpoint retrieves a liquidation monitoring record for an account.
 * 
 * GET /api/liquidation-monitoring?accountId=0x...
 * 
 * Query parameters:
 * - accountId: string (required) - bytes32 account ID
 * 
 * Response:
 * {
 *   success: boolean,
 *   record?: {
 *     id: number,
 *     accountId: string,
 *     totalCollateral: string,
 *     maintenanceMargin: string,
 *     collateralToken: string,
 *     createdAt: string,
 *     updatedAt: string
 *   },
 *   message?: string
 * }
 */
export async function GET(request: NextRequest) {
  try {
    const { searchParams } = new URL(request.url);
    
    const accountId = searchParams.get('accountId');
    
    // Validate required parameters
    if (!accountId) {
      return NextResponse.json(
        { success: false, message: 'Missing required parameter: accountId' },
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
    
    // Query the liquidation monitoring record
    const result = await sql`
      SELECT 
        id,
        account_id as "accountId",
        total_collateral as "totalCollateral",
        maintenance_margin as "maintenanceMargin",
        collateral_token as "collateralToken",
        created_at as "createdAt",
        updated_at as "updatedAt"
      FROM liquidation_monitoring 
      WHERE account_id = ${accountId}
    `;
    
    if (result.length === 0) {
      return NextResponse.json(
        { success: false, message: 'No liquidation monitoring record found for the specified account' },
        { status: 404 }
      );
    }
    
    const record = result[0];
    
    console.log('[Liquidation Monitoring] Record retrieved successfully:');
    console.log('  Account ID:', accountId);
    console.log('  Total Collateral:', record.totalCollateral);
    console.log('  Maintenance Margin:', record.maintenanceMargin);
    console.log('  Collateral Token:', record.collateralToken);
    
    return NextResponse.json({
      success: true,
      record: {
        id: record.id,
        accountId: record.accountId,
        totalCollateral: record.totalCollateral,
        maintenanceMargin: record.maintenanceMargin,
        collateralToken: record.collateralToken,
        createdAt: record.createdAt,
        updatedAt: record.updatedAt
      }
    });
    
  } catch (error) {
    console.error('[Liquidation Monitoring] Error retrieving record:', error);
    return NextResponse.json(
      { success: false, message: 'Internal server error' },
      { status: 500 }
    );
  }
}