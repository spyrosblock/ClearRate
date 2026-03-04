import { NextRequest, NextResponse } from 'next/server';
import { sql } from '@/lib/db';

/**
 * Get Liquidation Targets API
 *
 * This endpoint retrieves liquidation targets from the liquidation_monitoring table.
 * Liquidation targets are accounts where total_collateral is less than maintenance_margin.
 *
 * GET /api/liquidation-monitoring/targets
 *
 * Response:
 * {
 *   success: boolean,
 *   liquidationTargets?: Array<{
 *     accountId: string,
 *     collateralToken: string,
 *     totalCollateral: string,
 *     maintenanceMargin: string
 *   }>,
 *   count?: number,
 *   message?: string
 * }
 */
export async function GET(request: NextRequest) {
  try {
    // Query liquidation targets where total_collateral < maintenance_margin
    const result = await sql`
      SELECT
        account_id as "accountId",
        collateral_token as "collateralToken",
        total_collateral as "totalCollateral",
        maintenance_margin as "maintenanceMargin"
      FROM liquidation_monitoring
      WHERE total_collateral < maintenance_margin
    `;

    const liquidationTargets = result.map((row) => ({
      accountId: row.accountId,
      collateralToken: row.collateralToken,
      totalCollateral: row.totalCollateral,
      maintenanceMargin: row.maintenanceMargin,
    }));

    console.log(
      '[Liquidation Monitoring] Liquidation targets retrieved successfully:'
    );
    console.log('  Count:', liquidationTargets.length);

    liquidationTargets.forEach((target) => {
      console.log('  Account ID:', target.accountId);
      console.log('  Collateral Token:', target.collateralToken);
      console.log('  Total Collateral:', target.totalCollateral);
      console.log('  Maintenance Margin:', target.maintenanceMargin);
    });

    return NextResponse.json({
      success: true,
      liquidationTargets,
      count: liquidationTargets.length,
    });
  } catch (error) {
    console.error(
      '[Liquidation Monitoring] Error retrieving liquidation targets:',
      error
    );
    return NextResponse.json(
      { success: false, message: 'Internal server error' },
      { status: 500 }
    );
  }
}
