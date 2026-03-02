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
 *     lei: string,          // Legal Entity Identifier (20 alphanumeric characters)
 *     website: string,      // Company website URL
 *     uploadedLegalDocs: {
 *       articlesOfAssociation: string,    // URL to document
 *       certificateOfIncorporation: string, // URL to document
 *       vatCertificate: string           // URL to document
 *     },
 *     bankDetails: {
 *       iban: string,
 *       bic: string
 *     }
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
    
    // Validate website
    if (!company.website) {
      return NextResponse.json(
        { approved: false, reason: 'Missing required company field: website' },
        { status: 400 }
      );
    }
    
    // Validate uploaded legal documents
    if (!company.uploadedLegalDocs) {
      return NextResponse.json(
        { approved: false, reason: 'Missing required company field: uploadedLegalDocs' },
        { status: 400 }
      );
    }
    if (!company.uploadedLegalDocs.articlesOfAssociation || 
        !company.uploadedLegalDocs.certificateOfIncorporation || 
        !company.uploadedLegalDocs.vatCertificate) {
      return NextResponse.json(
        { approved: false, reason: 'Missing required legal documents: articlesOfAssociation, certificateOfIncorporation, vatCertificate' },
        { status: 400 }
      );
    }
    
    // Validate bank details
    if (!company.bankDetails) {
      return NextResponse.json(
        { approved: false, reason: 'Missing required company field: bankDetails' },
        { status: 400 }
      );
    }
    if (!company.bankDetails.iban || !company.bankDetails.bic) {
      return NextResponse.json(
        { approved: false, reason: 'Missing required bank details: iban, bic' },
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
    console.log('  Website:', company.website);
    console.log('  Legal Docs:');
    console.log('    Articles of Association:', company.uploadedLegalDocs.articlesOfAssociation);
    console.log('    Certificate of Incorporation:', company.uploadedLegalDocs.certificateOfIncorporation);
    console.log('    VAT Certificate:', company.uploadedLegalDocs.vatCertificate);
    console.log('  Bank Details:');
    console.log('    IBAN:', company.bankDetails.iban);
    console.log('    BIC:', company.bankDetails.bic);
    
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

