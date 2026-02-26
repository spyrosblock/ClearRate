import { NextResponse } from 'next/server';

/**
 * GET /api/margin/variation-margin
 * 
 * Returns hardcoded variation margin settlement data for testing the settle-vm-workflow.
 * 
 * Expected response structure matches the vmSettlementPayloadSchema in settle-vm-workflow/main.ts:
 * - tradeId: bytes32 hex string (64 characters, may include 0x prefix)
 * - npvChange: string representation of int256 (positive = NPV increased from fixed payer's perspective)
 * - isFinal: boolean indicating if this is a final matured position settlement (true) or regular VM settlement (false)
 * 
 * For variation margin (regular VM settlement), isFinal should be false.
 * For matured position settlements, isFinal should be true.
 */
export async function GET() {
  const variationMarginData = {
    settlements: [
      {
        tradeId: "0x0000000000000000000000000000000000000000000000000000000000000001",
        npvChange: "1000000000000000000", // 1 WAD = positive NPV change (benefits party A)
        isFinal: false // Regular VM settlement (not matured position)
      },
      {
        tradeId: "0x0000000000000000000000000000000000000000000000000000000000000002",
        npvChange: "-1000000000000000000", // -1 WAD = negative NPV change (benefits party B)
        isFinal: false // Regular VM settlement (not matured position)
      }
    ],
    metadata: {
      settlementDate: new Date().toISOString().split('T')[0],
      npvSource: "internal"
    }
  };

  return NextResponse.json(variationMarginData);
}
