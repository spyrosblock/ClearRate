import { NextResponse } from 'next/server';

/**
 * GET /api/margin/variation-margin
 * 
 * Returns hardcoded variation margin settlement data for testing the settle-vm-workflow.
 * 
 * Expected response structure matches the VMSettlement struct in ClearingHouse.sol:
 * - tradeId: bytes32 unique trade identifier
 * - npvChange: signed int256 (positive = NPV increased from fixed payer's perspective)
 */
export async function GET() {
  const variationMarginData = {
    settlements: [
      {
        tradeId: "0x0000000000000000000000000000000000000000000000000000000000000001",
        npvChange: "1000000000000000000" // 1 WAD = positive NPV change (benefits party A)
      },
      {
        tradeId: "0x0000000000000000000000000000000000000000000000000000000000000002",
        npvChange: "-1000000000000000000" // -1 WAD = negative NPV change (benefits party B)
      }
    ],
    metadata: {
      settlementDate: new Date().toISOString().split('T')[0],
      npvSource: "internal",
      note: "npvChange is from fixed payer's perspective - positive benefits party A, negative benefits party B"
    }
  };

  return NextResponse.json(variationMarginData);
}
