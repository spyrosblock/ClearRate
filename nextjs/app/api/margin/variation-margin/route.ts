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
        tradeId: "0xa7acfb24dc069ee589e5667ccc60811c0c210f8b4725d66b8d4ef412d39d3b2e",
        npvChange: "1000000000000000000", // 1 WAD = positive NPV change (benefits party A)
        isFinal: true // Regular VM settlement (not matured position)
      },
      {
        tradeId: "0x0313f4e15d0bc0afbed03fa18bc19430ba6afbc16396d17bafa82a53348b09b3",
        npvChange: "-2000000000000000000", // -1 WAD = negative NPV change (benefits party B)
        isFinal: true // Regular VM settlement (not matured position)
      }
    ],
    metadata: {
      settlementDate: new Date().toISOString().split('T')[0],
      npvSource: "internal"
    }
  };

  return NextResponse.json(variationMarginData);
}
