import { NextRequest, NextResponse } from 'next/server';

/**
 * Mock KYC Verification API
 * 
 * This endpoint approves every user with tier 3 (Institutional)
 * It accepts user data and returns whitelist parameters.
 * 
 * Request body:
 * {
 *   address: string,        // Ethereum address
 *   accountId: string,      // Account ID
 *   personal?: {            // Optional personal data
 *     firstName: string,
 *     lastName: string,
 *     email: string,
 *     dateOfBirth: string,
 *     country: string
 *   },
 *   company?: {             // Optional company data
 *     companyName: string,
 *     registrationNumber: string,
 *     registeredCountry: string,
 *     contactEmail: string
 *   }
 * }
 * 
 * Response:
 * {
 *   approved: boolean,
 *   tier: number,
 *   customMaxNotional?: string,
 *   kycExpiry?: number,     // Unix timestamp
 *   reason?: string
 * }
 */
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    
    const { address, accountId, personal, company } = body;
    
    // Validate required fields
    if (!address || !accountId) {
      return NextResponse.json(
        { approved: false, reason: 'Missing required fields: address and accountId' },
        { status: 400 }
      );
    }
    
    // Validate Ethereum address format
    if (!/^0x[a-fA-F0-9]{40}$/.test(address)) {
      return NextResponse.json(
        { approved: false, reason: 'Invalid Ethereum address format' },
        { status: 400 }
      );
    }
    
    // Validate accountId format
    if (!/^0x[a-fA-F0-9]{64}$/.test(accountId)) {
      return NextResponse.json(
        { approved: false, reason: 'Invalid account ID format' },
        { status: 400 }
      );
    }
    
    // Log the verification request
    console.log('[KYC Mock] Verification request received:');
    console.log('  Address:', address);
    console.log('  Account ID:', accountId);
    
    if (personal) {
      console.log('  Type: Personal');
      console.log('  Name:', personal.firstName, personal.lastName);
      console.log('  Email:', personal.email);
      console.log('  Country:', personal.country);
    } else if (company) {
      console.log('  Type: Company');
      console.log('  Company:', company.companyName);
      console.log('  Registration:', company.registrationNumber);
      console.log('  Country:', company.registeredCountry);
    }
    
    // Mock KYC verification - always approve with tier 3
    // Tier 3 = Institutional - $10M max notional
    const oneYearFromNow = Math.floor(Date.now() / 1000) + (365 * 24 * 60 * 60);
    
    // Tier 3 default max notional is 10_000_000 * 1e18 (as per Whitelist.sol)
    const maxNotional = (10_000_000 * 1_000_000_000_000_000_000).toString();
    
    const response = {
      approved: true,
      tier: 3,
      customMaxNotional: maxNotional,
      kycExpiry: oneYearFromNow,
    };
    
    console.log('[KYC Mock] Verification approved:');
    console.log('  Tier:', response.tier);
    console.log('  Max Notional:', response.customMaxNotional);
    console.log('  KYC Expiry:', new Date(response.kycExpiry * 1000).toISOString());
    
    return NextResponse.json(response);
    
  } catch (error) {
    console.error('[KYC Mock] Error processing request:', error);
    return NextResponse.json(
      { approved: false, reason: 'Internal server error' },
      { status: 500 }
    );
  }
}

