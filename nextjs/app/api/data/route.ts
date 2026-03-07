import { NextResponse } from 'next/server';
import { sql } from '@/lib/db';

/**
 * GET /api/data
 * 
 * Fetches all data from the 3 main tables: swap_positions, users, and liquidation_monitoring.
 * Returns a nicely structured response with all data combined.
 * 
 * Response structure:
 * - success: boolean indicating operation success
 * - data: object containing:
 *   - swapPositions: array of swap position records
 *   - users: array of user records
 *   - liquidationMonitoring: array of liquidation monitoring records
 * - summary: object with counts and statistics
 */
export async function GET() {
  try {
    // Fetch all data from the 3 tables in parallel
    const [swapPositions, users, liquidationMonitoring] = await Promise.all([
      sql`
        SELECT 
          id,
          token_id,
          owner_id,
          balance,
          notional,
          fixed_rate_bps,
          start_date,
          maturity_date,
          payment_interval,
          direction,
          floating_rate_index,
          day_count_convention,
          collateral_token,
          active,
          last_npv,
          created_at,
          updated_at
        FROM swap_positions
        ORDER BY created_at DESC
      `,
      sql`
        SELECT 
          id,
          address,
          account_id,
          company_name,
          registration_number,
          registered_country,
          contact_email,
          lei,
          website,
          articles_of_association,
          certificate_of_incorporation,
          vat_certificate,
          iban,
          bic,
          approved,
          valid_until,
          max_notional,
          notional,
          created_at,
          updated_at
        FROM users
        ORDER BY created_at DESC
      `,
      sql`
        SELECT 
          id,
          account_id,
          total_collateral,
          maintenance_margin,
          collateral_token,
          created_at,
          updated_at
        FROM liquidation_monitoring
        ORDER BY updated_at DESC
      `,
    ]);

    // Calculate summary statistics
    const totalNotional = swapPositions.reduce((sum, pos) => {
      return sum + BigInt(pos.notional as string);
    }, BigInt(0));

    const activePositions = swapPositions.filter((pos) => pos.active as boolean).length;
    const approvedUsers = users.filter((user) => user.approved as boolean).length;
    const totalCollateral = liquidationMonitoring.reduce((sum, lm) => {
      return sum + BigInt(lm.total_collateral as string);
    }, BigInt(0));
    const totalMaintenanceMargin = liquidationMonitoring.reduce((sum, lm) => {
      return sum + BigInt(lm.maintenance_margin as string);
    }, BigInt(0));

    // Helper function to format timestamps
    const formatTimestamp = (timestamp: Date | string | null) => {
      if (!timestamp) return null;
      return new Date(timestamp).toISOString();
    };

    // Helper function to format direction
    const formatDirection = (direction: number) => {
      return direction === 0 ? 'PAY_FIXED' : 'RECEIVE_FIXED';
    };

    // Helper function to format day count convention
    const formatDayCountConvention = (convention: number) => {
      const conventions = ['ACT/360', 'ACT/365', '30/360'];
      return conventions[convention] || 'UNKNOWN';
    };

    // Format swap positions for better readability
    const formattedSwapPositions = swapPositions.map((pos) => ({
      id: pos.id as number,
      tokenId: pos.token_id as string,
      ownerId: pos.owner_id as string,
      balance: pos.balance as string,
      notional: pos.notional as string,
      fixedRateBps: pos.fixed_rate_bps as number,
      fixedRatePercent: ((pos.fixed_rate_bps as number) / 100).toFixed(2) + '%',
      startDate: formatTimestamp(pos.start_date as Date | string),
      maturityDate: formatTimestamp(pos.maturity_date as Date | string),
      paymentIntervalSeconds: pos.payment_interval as string,
      direction: formatDirection(pos.direction as number),
      directionCode: pos.direction as number,
      floatingRateIndex: pos.floating_rate_index as string,
      dayCountConvention: formatDayCountConvention(pos.day_count_convention as number),
      dayCountConventionCode: pos.day_count_convention as number,
      collateralToken: pos.collateral_token as string,
      active: pos.active as boolean,
      lastNpv: pos.last_npv as string,
      createdAt: formatTimestamp(pos.created_at as Date | string),
      updatedAt: formatTimestamp(pos.updated_at as Date | string),
    }));

    // Format users for better readability
    const formattedUsers = users.map((user) => ({
      id: user.id as number,
      address: user.address as string,
      accountId: user.account_id as string | null,
      companyName: user.company_name as string,
      registrationNumber: user.registration_number as string,
      registeredCountry: user.registered_country as string,
      contactEmail: user.contact_email as string,
      lei: user.lei as string,
      website: user.website as string,
      documents: {
        articlesOfAssociation: user.articles_of_association as string | null,
        certificateOfIncorporation: user.certificate_of_incorporation as string | null,
        vatCertificate: user.vat_certificate as string | null,
      },
      banking: {
        iban: user.iban as string,
        bic: user.bic as string,
      },
      status: {
        approved: user.approved as boolean,
        validUntil: formatTimestamp(user.valid_until as Date | string | null),
      },
      limits: {
        maxNotional: user.max_notional as string,
        currentNotional: user.notional as string,
        availableNotional: (BigInt(user.max_notional as string) - BigInt(user.notional as string)).toString(),
      },
      createdAt: formatTimestamp(user.created_at as Date | string),
      updatedAt: formatTimestamp(user.updated_at as Date | string),
    }));

    // Format liquidation monitoring records for better readability
    const formattedLiquidationMonitoring = liquidationMonitoring.map((lm) => {
      const collateral = BigInt(lm.total_collateral as string);
      const mm = BigInt(lm.maintenance_margin as string);
      const isUnderCollateralized = collateral < mm;
      
      return {
        id: lm.id as number,
        accountId: lm.account_id as string,
        collateral: {
          total: lm.total_collateral as string,
          maintenanceMargin: lm.maintenance_margin as string,
        },
        collateralToken: lm.collateral_token as string,
        healthStatus: {
          isUnderCollateralized,
          marginRatio: mm > BigInt(0) ? ((collateral * BigInt(100)) / mm).toString() + '%' : 'N/A',
        },
        createdAt: formatTimestamp(lm.created_at as Date | string),
        updatedAt: formatTimestamp(lm.updated_at as Date | string),
      };
    });

    const response = {
      success: true,
      data: {
        swapPositions: formattedSwapPositions,
        users: formattedUsers,
        liquidationMonitoring: formattedLiquidationMonitoring,
      },
      summary: {
        swapPositions: {
          total: swapPositions.length,
          active: activePositions,
          inactive: swapPositions.length - activePositions,
          totalNotional: totalNotional.toString(),
        },
        users: {
          total: users.length,
          approved: approvedUsers,
          pending: users.length - approvedUsers,
        },
        liquidationMonitoring: {
          totalAccounts: liquidationMonitoring.length,
          totalCollateral: totalCollateral.toString(),
          totalMaintenanceMargin: totalMaintenanceMargin.toString(),
          underCollateralizedAccounts: formattedLiquidationMonitoring.filter(
            (lm) => lm.healthStatus.isUnderCollateralized
          ).length,
        },
        timestamp: new Date().toISOString(),
      },
    };

    return NextResponse.json(response);
  } catch (error) {
    console.error('Error fetching data:', error);
    
    return NextResponse.json(
      { 
        success: false,
        error: 'Failed to fetch data from database' 
      },
      { status: 500 }
    );
  }
}