import { NextResponse } from 'next/server';
import { sql } from '@/lib/db';

/**
 * Swap position data structure matching the swap_positions table schema.
 * This represents an IRS position from the database.
 */
interface SwapPosition {
  token_id: string;              // uint256 as string (ERC-1155 token ID)
  owner_id: string;              // bytes32 account ID (pays fixed)
  balance: string;               // Balance amount (uint256 as string)
  notional: string;              // Notional amount (uint256 as string)
  fixed_rate_bps: number;        // Fixed rate in basis points
  start_date: string;            // Swap effective date (ISO string)
  maturity_date: string;         // Swap maturity date (ISO string)
  payment_interval: string;      // Payment interval in seconds (uint256 as string)
  direction: number;             // Direction of the swap (0=PAY_FIXED, 1=RECEIVE_FIXED)
  floating_rate_index: string;   // Floating rate index (bytes32 as hex string)
  day_count_convention: number;  // Day count convention (0=ACT/360, 1=ACT/365, 2=30/360)
  collateral_token: string;      // Collateral token address
  active: boolean;               // Position active status
  last_npv?: string;             // Last mark-to-market NPV (optional)
}

/**
 * NPV Change entry - matches NPVChange struct from ClearingHouse contract.
 */
interface NPVChange {
  tokenId: string;   // uint256 as string
  npvChange: string; // int256 as string (can be negative)
  isFinal: boolean;  // Indicates if this is the final settlement for the token ID.
}

/**
 * VM Settlement entry - matches VMSettlement struct from ClearingHouse contract.
 */
interface VMSettlement {
  accountId: string;       // bytes32 as hex string
  collateralToken: string; // address
  vmChange: string;        // int256 as string (can be negative)
}

/**
 * Constant NPV change value (5,000 tokens with 18 decimals).
 * This is used as a placeholder for actual NPV calculation.
 */
const CONSTANT_NPV_CHANGE = BigInt('5000000000000000000000'); // 5000e18

/**
 * Get NPV change for a position.
 * Returns the CONSTANT_NPV_CHANGE based on the position's direction.
 * 
 * @param position - The swap position
 * @returns The NPV change as a signed bigint
 */
function getNpvChange(position: SwapPosition): bigint {
  // For PAY_FIXED (0): positive NPV change
  // For RECEIVE_FIXED (1): negative NPV change
  if (position.direction === 1) {
    return -CONSTANT_NPV_CHANGE;
  }
  
  return CONSTANT_NPV_CHANGE;
}

/**
 * Calculate VM change for a position based on its balance/notional ratio.
 * 
 * Formula: (balance / notional) * NPV change from getNpvChange
 * 
 * @param position - The swap position
 * @returns The calculated VM change as a signed bigint
 */
function calculateVMChange(position: SwapPosition): bigint {
  const balance = BigInt(position.balance);
  const notional = BigInt(position.notional);
  
  // Avoid division by zero
  if (notional === BigInt(0)) {
    return BigInt(0);
  }
  
  // Get NPV change for this position
  const npvChange = getNpvChange(position);
  
  // Calculate: (balance * npvChange) / notional
  const vmChange = (balance * npvChange) / notional;
  
  return vmChange;
}

/**
 * POST /api/variation-margin
 * 
 * Queries swap positions from the database and calculates variation margin settlements.
 * 
 * Response structure:
 * - npvChanges: Array of NPVChange entries (one per token)
 * - vmSettlements: Array of VMSettlement entries (aggregated by account/collateral)
 * - metadata: Settlement metadata including date and counts
 */
export async function POST(request: Request) {
  try {
    // Query active positions from the swap_positions table
    const positions = await sql`
      SELECT 
        token_id,
        owner_id,
        balance::text as balance,
        notional::text as notional,
        fixed_rate_bps,
        start_date::text as start_date,
        maturity_date::text as maturity_date,
        payment_interval::text as payment_interval,
        direction,
        floating_rate_index,
        day_count_convention,
        collateral_token,
        active,
        COALESCE(last_npv::text, '0') as last_npv
      FROM swap_positions
      WHERE active = TRUE
    ` as SwapPosition[];
    
    if (positions.length === 0) {
      return NextResponse.json(
        {
          npvChanges: [],
          vmSettlements: [],
          settlements: [],
          metadata: {
            settlementDate: new Date().toISOString().split('T')[0],
            npvSource: 'constant',
            positionsCount: 0,
            activePositionsCount: 0,
          }
        },
        { status: 200 }
      );
    }

    // Create NPV changes array - one entry per unique token (deduplicated)
    const npvChangesMap = new Map<string, NPVChange>();
    
    for (const position of positions) {
      // Skip if we already have an entry for this token
      if (npvChangesMap.has(position.token_id)) {
        continue;
      }
      
      // Get NPV change for this position using getNpvChange function
      const npvChange = getNpvChange(position).toString();
      
      npvChangesMap.set(position.token_id, {
        tokenId: position.token_id,
        npvChange: npvChange,
        isFinal: false, // Regular VM settlement, not final
      });
    }
    
    const npvChanges: NPVChange[] = Array.from(npvChangesMap.values());

    // Aggregate VM settlements by account/collateral token
    // Key: "accountId:collateralToken", Value: aggregated VM change
    const vmSettlementMap = new Map<string, bigint>();
    
    for (const position of positions) {
      const vmChange = calculateVMChange(position);
      const key = `${position.owner_id}:${position.collateral_token}`;
      
      const existingChange = vmSettlementMap.get(key) || BigInt(0);
      vmSettlementMap.set(key, existingChange + vmChange);
    }
    
    // Convert map to VMSettlement array
    const vmSettlements: VMSettlement[] = [];
    for (const [key, vmChange] of vmSettlementMap.entries()) {
      const [accountId, collateralToken] = key.split(':');
      vmSettlements.push({
        accountId,
        collateralToken,
        vmChange: vmChange.toString(),
      });
    }

    const response = {
      npvChanges,
      vmSettlements,
      metadata: {
        settlementDate: new Date().toISOString().split('T')[0],
        npvSource: 'constant',
        positionsCount: positions.length,
        activePositionsCount: positions.length,
        npvChangesCount: npvChanges.length,
        vmSettlementsCount: vmSettlements.length,
      },
    };

    return NextResponse.json(response);
  } catch (error) {
    console.error('Error processing variation margin request:', error);
    return NextResponse.json(
      { error: 'Failed to process positions' },
      { status: 500 }
    );
  }
}
