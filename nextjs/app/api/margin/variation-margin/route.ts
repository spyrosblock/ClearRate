import { NextResponse } from 'next/server';

/**
 * GET /api/margin/variation-margin
 * 
 * Returns hardcoded variation margin settlement data for testing the settle-vm-workflow.
 * 
 * Expected response structure matches the VMSettlement struct in ClearingHouse.sol:
 * - accountId: bytes32 identifier
 * - vmAmount: signed int256 (positive = credit, negative = debit)
 */
export async function GET() {
  const variationMarginData = {
    settlements: [
      {
        accountId: "0x0000000000000000000000000000000000000000000000000000000000000001",
        vmAmount: "1000000000000000000" // 1 WAD = credit
      },
      {
        accountId: "0x0000000000000000000000000000000000000000000000000000000000000002",
        vmAmount: "-1000000000000000000" // -1 WAD = debit
      }
    ],
    metadata: {
      settlementDate: new Date().toISOString().split('T')[0],
      npvSource: "internal"
    }
  };

  return NextResponse.json(variationMarginData);
}
