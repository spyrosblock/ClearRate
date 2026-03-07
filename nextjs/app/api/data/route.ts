import { NextResponse } from 'next/server';
import { sql } from '@/lib/db';

/**
 * GET /api/data
 * 
 * Fetches all data from the 3 main tables: swap_positions, users, and liquidation_monitoring.
 * Returns a formatted plain text response with ASCII tables for terminal viewing.
 */
export async function GET() {
  try {
    // Fetch all data from the 3 tables in parallel
    const [swapPositions, users, liquidationMonitoring] = await Promise.all([
      sql`SELECT * FROM swap_positions ORDER BY created_at DESC`,
      sql`SELECT * FROM users ORDER BY created_at DESC`,
      sql`SELECT * FROM liquidation_monitoring ORDER BY updated_at DESC`,
    ]);

    // Helper to format timestamp
    const formatTs = (ts: unknown) => {
      if (!ts) return 'N/A';
      try {
        return new Date(ts as Date | string).toISOString().slice(0, 19).replace('T', ' ');
      } catch {
        return String(ts);
      }
    };

    // Helper to truncate string
    const truncate = (str: string, maxLen: number) => {
      if (!str) return '';
      return str.length > maxLen ? str.slice(0, maxLen - 3) + '...' : str;
    };

    // Helper to format direction
    const formatDirection = (d: unknown) => d === 0 ? 'PAY_FIXED' : 'RECV_FIXED';

    // Helper to format day count
    const formatDayCount = (d: unknown) => {
      const conventions = ['ACT/360', 'ACT/365', '30/360'];
      return conventions[d as number] || 'UNKNOWN';
    };

    let output = '';

    // Header
    output += '\n' + '='.repeat(100) + '\n';
    output += '                              CLEARRATE DATABASE SNAPSHOT\n';
    output += '='.repeat(100) + '\n';
    output += `Generated at: ${new Date().toISOString()}\n\n`;

    // ============ SWAP POSITIONS TABLE ============
    output += '┌' + '─'.repeat(98) + '┐\n';
    output += '│' + ' SWAP POSITIONS'.padEnd(98) + '│\n';
    output += '├' + '─'.repeat(98) + '┤\n';

    if (swapPositions.length === 0) {
      output += '│' + ' (no positions found)'.padEnd(98) + '│\n';
    } else {
      // Table header
      const header = '│ ID │ Token ID        │ Owner ID       │ Notional        │ Rate    │ Direction   │ Start              │ Maturity           │ Active │';
      output += header + '\n';
      output += '├' + '─'.repeat(4) + '┼' + '─'.repeat(16) + '┼' + '─'.repeat(15) + '┼' + '─'.repeat(16) + '┼' + '─'.repeat(8) + '┼' + '─'.repeat(12) + '┼' + '─'.repeat(19) + '┼' + '─'.repeat(19) + '┼' + '─'.repeat(7) + '┤\n';

      for (const pos of swapPositions) {
        const id = String(pos.id).padEnd(2).slice(0, 2);
        const tokenId = truncate(String(pos.token_id), 14).padEnd(14);
        const ownerId = truncate(String(pos.owner_id), 13).padEnd(13);
        const notional = truncate(String(pos.notional), 14).padEnd(14);
        const rate = (String(pos.fixed_rate_bps / 100) + '%').padEnd(6);
        const direction = formatDirection(pos.direction).padEnd(10);
        const startDate = formatTs(pos.start_date).slice(0, 19);
        const maturityDate = formatTs(pos.maturity_date).slice(0, 19);
        const active = pos.active ? 'Yes' : 'No';

        output += `│ ${id} │ ${tokenId} │ ${ownerId} │ ${notional} │ ${rate} │ ${direction} │ ${startDate} │ ${maturityDate} │ ${active.padEnd(5)} │\n`;
      }
    }
    output += '└' + '─'.repeat(98) + '┘\n';
    output += `Total: ${swapPositions.length} | Active: ${swapPositions.filter(p => p.active).length} | Inactive: ${swapPositions.filter(p => !p.active).length}\n\n`;

    // ============ USERS TABLE ============
    output += '┌' + '─'.repeat(98) + '┐\n';
    output += '│' + ' USERS'.padEnd(98) + '│\n';
    output += '├' + '─'.repeat(98) + '┤\n';

    if (users.length === 0) {
      output += '│' + ' (no users found)'.padEnd(98) + '│\n';
    } else {
      const header = '│ ID │ Address         │ Company Name           │ Country │ Email                    │ Approved │ Max Notional     │';
      output += header + '\n';
      output += '├' + '─'.repeat(4) + '┼' + '─'.repeat(16) + '┼' + '─'.repeat(23) + '┼' + '─'.repeat(8) + '┼' + '─'.repeat(25) + '┼' + '─'.repeat(9) + '┼' + '─'.repeat(17) + '┤\n';

      for (const user of users) {
        const id = String(user.id).padEnd(2).slice(0, 2);
        const address = truncate(String(user.address), 14).padEnd(14);
        const company = truncate(String(user.company_name), 21).padEnd(21);
        const country = String(user.registered_country).padEnd(6);
        const email = truncate(String(user.contact_email), 23).padEnd(23);
        const approved = (user.approved ? '✓ Yes' : '✗ No').padEnd(7);
        const maxNotional = truncate(String(user.max_notional || '0'), 15).padEnd(15);

        output += `│ ${id} │ ${address} │ ${company} │ ${country} │ ${email} │ ${approved} │ ${maxNotional} │\n`;
      }
    }
    output += '└' + '─'.repeat(98) + '┘\n';
    output += `Total: ${users.length} | Approved: ${users.filter(u => u.approved).length} | Pending: ${users.filter(u => !u.approved).length}\n\n`;

    // ============ LIQUIDATION MONITORING TABLE ============
    output += '┌' + '─'.repeat(98) + '┐\n';
    output += '│' + ' LIQUIDATION MONITORING'.padEnd(98) + '│\n';
    output += '├' + '─'.repeat(98) + '┤\n';

    if (liquidationMonitoring.length === 0) {
      output += '│' + ' (no monitoring records found)'.padEnd(98) + '│\n';
    } else {
      const header = '│ ID │ Account ID      │ Collateral Token    │ Total Collateral  │ Maintenance Margin │ Health    │ Updated            │';
      output += header + '\n';
      output += '├' + '─'.repeat(4) + '┼' + '─'.repeat(16) + '┼' + '─'.repeat(20) + '┼' + '─'.repeat(18) + '┼' + '─'.repeat(20) + '┼' + '─'.repeat(10) + '┼' + '─'.repeat(19) + '┤\n';

      for (const lm of liquidationMonitoring) {
        const id = String(lm.id).padEnd(2).slice(0, 2);
        const accountId = truncate(String(lm.account_id), 14).padEnd(14);
        const collateralToken = truncate(String(lm.collateral_token), 18).padEnd(18);
        const totalCollateral = truncate(String(lm.total_collateral), 16).padEnd(16);
        const maintenanceMargin = truncate(String(lm.maintenance_margin), 18).padEnd(18);
        
        // Calculate health status
        const collateral = BigInt(lm.total_collateral as string || '0');
        const mm = BigInt(lm.maintenance_margin as string || '0');
        const health = collateral >= mm ? '✓ OK' : '⚠ AT RISK';
        
        const updated = formatTs(lm.updated_at).slice(0, 19);

        output += `│ ${id} │ ${accountId} │ ${collateralToken} │ ${totalCollateral} │ ${maintenanceMargin} │ ${health.padEnd(8)} │ ${updated} │\n`;
      }
    }
    output += '└' + '─'.repeat(98) + '┘\n';

    const underCollateralized = liquidationMonitoring.filter(lm => {
      const collateral = BigInt(lm.total_collateral as string || '0');
      const mm = BigInt(lm.maintenance_margin as string || '0');
      return collateral < mm;
    }).length;

    output += `Total Accounts: ${liquidationMonitoring.length} | Under-collateralized: ${underCollateralized}\n\n`;

    // Footer
    output += '='.repeat(100) + '\n';

    return new NextResponse(output, {
      headers: {
        'Content-Type': 'text/plain; charset=utf-8',
      },
    });
  } catch (error) {
    console.error('Error fetching data:', error);
    
    const errorOutput = '\n' + '='.repeat(50) + '\n' +
      'ERROR: Failed to fetch data from database\n' +
      '='.repeat(50) + '\n';
    
    return new NextResponse(errorOutput, {
      status: 500,
      headers: {
        'Content-Type': 'text/plain; charset=utf-8',
      },
    });
  }
}