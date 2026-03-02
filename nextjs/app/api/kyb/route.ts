import { NextRequest, NextResponse } from 'next/server';

/**
 * Whitelist API
 * 
 * This endpoint validates company data and returns approval status with validity period.
 * 
 * Request body:
 * {
 *   address: string,        // Ethereum address
 *   accountId: string,      // Account ID (bytes32 hex)
 *   company: {              // Required company data
 *     companyName: string,
 *     registrationNumber: string,
 *     registeredCountry: string,
 *     contactEmail: string,
 *     lei: string           // Legal Entity Identifier (20 alphanumeric characters)
 *   }
 * }
 * 
 * Response:
 * {
 *   approved: boolean,
 *   validUntil: number,     // Unix timestamp for whitelist expiry
 *   reason?: string         // Only present if not approved
 * }
 */
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    
    const { address, accountId, company } = body;
    
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
    
    // Validate company data
    if (!company) {
      return NextResponse.json(
        { approved: false, reason: 'Company data is required' },
        { status: 400 }
      );
    }
    
    // Validate company fields
    if (!company.companyName || !company.registrationNumber || !company.registeredCountry || !company.contactEmail) {
      return NextResponse.json(
        { approved: false, reason: 'Missing required company fields: companyName, registrationNumber, registeredCountry, contactEmail' },
        { status: 400 }
      );
    }
    
    // Validate LEI (Legal Entity Identifier) - 20 alphanumeric characters
    if (!company.lei) {
      return NextResponse.json(
        { approved: false, reason: 'Missing required company field: lei' },
        { status: 400 }
      );
    }
    if (!/^[A-Z0-9]{20}$/.test(company.lei)) {
      return NextResponse.json(
        { approved: false, reason: 'Invalid LEI format - must be 20 alphanumeric characters' },
        { status: 400 }
      );
    }
    
    // Log the verification request
    console.log('[KYB Mock] Verification request received:');
    console.log('  Address:', address);
    console.log('  Account ID:', accountId);
    console.log('  Type: Company');
    console.log('  Company:', company.companyName);
    console.log('  Registration:', company.registrationNumber);
    console.log('  Country:', company.registeredCountry);
    console.log('  Contact Email:', company.contactEmail);
    console.log('  LEI:', company.lei);
    
    // Calculate validUntil: 1 year from now
    const validUntil = Math.floor(Date.now() / 1000) + 365 * 24 * 60 * 60;
    
    // All valid requests are approved
    const response = {
      approved: true,
      validUntil,
    };
    
    console.log('[KYB Mock] Verification approved, validUntil:', new Date(validUntil * 1000).toISOString());
    
    return NextResponse.json(response);
    
  } catch (error) {
    console.error('[KYB Mock] Error processing request:', error);
    return NextResponse.json(
      { approved: false, reason: 'Internal server error' },
      { status: 500 }
    );
  }
}

