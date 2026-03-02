import { NextRequest, NextResponse } from 'next/server';

/**
 * Risk Management API
 * 
 * This endpoint calculates and returns risk parameters for whitelisted participants.
 * 
 * Request body:
 * {
 *   address: string,        // Ethereum address
 *   accountId: string,      // Account ID (bytes32 hex)
 *   company: {              // Company data for risk assessment
 *     companyName: string,
 *     registrationNumber: string,
 *     registeredCountry: string,
 *     contactEmail: string,
 *     lei: string,
 *     website: string,
 *     uploadedLegalDocs: {
 *       articlesOfAssociation: string,
 *       certificateOfIncorporation: string,
 *       vatCertificate: string
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
 *   maxNotional: string,    // Maximum notional amount as string (to handle large numbers)
 *   reason?: string         // Optional explanation
 * }
 */

interface UploadedLegalDocs {
  articlesOfAssociation: string;
  certificateOfIncorporation: string;
  vatCertificate: string;
}

interface BankDetails {
  iban: string;
  bic: string;
}

interface CompanyData {
  companyName: string;
  registrationNumber: string;
  registeredCountry: string;
  contactEmail: string;
  lei: string;
  website: string;
  uploadedLegalDocs: UploadedLegalDocs;
  bankDetails: BankDetails;
}

interface RiskRequest {
  address: string;
  accountId: string;
  company: CompanyData;
}

export async function POST(request: NextRequest) {
  try {
    const body: RiskRequest = await request.json();
    
    const { address, accountId, company } = body;
    
    // Validate required fields
    if (!address || !accountId) {
      return NextResponse.json(
        { maxNotional: '0', reason: 'Missing required fields: address and accountId' },
        { status: 400 }
      );
    }
    
    // Validate Ethereum address format
    if (!/^0x[a-fA-F0-9]{40}$/.test(address)) {
      return NextResponse.json(
        { maxNotional: '0', reason: 'Invalid Ethereum address format' },
        { status: 400 }
      );
    }
    
    // Validate accountId format
    if (!/^0x[a-fA-F0-9]{64}$/.test(accountId)) {
      return NextResponse.json(
        { maxNotional: '0', reason: 'Invalid account ID format' },
        { status: 400 }
      );
    }
    
    // Validate company data
    if (!company) {
      return NextResponse.json(
        { maxNotional: '0', reason: 'Company data is required for risk assessment' },
        { status: 400 }
      );
    }
    
    // Validate company fields
    if (!company.companyName || !company.registrationNumber || !company.registeredCountry || !company.contactEmail) {
      return NextResponse.json(
        { maxNotional: '0', reason: 'Missing required company fields' },
        { status: 400 }
      );
    }
    
    // Validate LEI
    if (!company.lei || !/^[A-Z0-9]{20}$/.test(company.lei)) {
      return NextResponse.json(
        { maxNotional: '0', reason: 'Invalid LEI format' },
        { status: 400 }
      );
    }
    
    // Validate website
    if (!company.website) {
      return NextResponse.json(
        { maxNotional: '0', reason: 'Missing required company field: website' },
        { status: 400 }
      );
    }
    
    // Validate uploaded legal documents
    if (!company.uploadedLegalDocs) {
      return NextResponse.json(
        { maxNotional: '0', reason: 'Missing required company field: uploadedLegalDocs' },
        { status: 400 }
      );
    }
    if (!company.uploadedLegalDocs.articlesOfAssociation || 
        !company.uploadedLegalDocs.certificateOfIncorporation || 
        !company.uploadedLegalDocs.vatCertificate) {
      return NextResponse.json(
        { maxNotional: '0', reason: 'Missing required legal documents' },
        { status: 400 }
      );
    }
    
    // Validate bank details
    if (!company.bankDetails) {
      return NextResponse.json(
        { maxNotional: '0', reason: 'Missing required company field: bankDetails' },
        { status: 400 }
      );
    }
    if (!company.bankDetails.iban || !company.bankDetails.bic) {
      return NextResponse.json(
        { maxNotional: '0', reason: 'Missing required bank details: iban, bic' },
        { status: 400 }
      );
    }
    
    // Log the risk assessment request
    console.log('[Risk Management] Assessment request received:');
    console.log('  Address:', address);
    console.log('  Account ID:', accountId);
    console.log('  Company:', company.companyName);
    console.log('  Country:', company.registeredCountry);
    console.log('  LEI:', company.lei);
    console.log('  Website:', company.website);
    console.log('  Legal Docs:');
    console.log('    Articles of Association:', company.uploadedLegalDocs.articlesOfAssociation);
    console.log('    Certificate of Incorporation:', company.uploadedLegalDocs.certificateOfIncorporation);
    console.log('    VAT Certificate:', company.uploadedLegalDocs.vatCertificate);
    console.log('  Bank Details:');
    console.log('    IBAN:', company.bankDetails.iban);
    console.log('    BIC:', company.bankDetails.bic);
    
    
    // Return the risk assessment
    const response = {
      maxNotional: '100_000_000_000000000000000000' // 10M USD in wei
    };
    
    console.log('[Risk Management] Assessment result:', response);
    
    return NextResponse.json(response);
    
  } catch (error) {
    console.error('[Risk Management] Error processing request:', error);
    return NextResponse.json(
      { maxNotional: '0', reason: 'Internal server error' },
      { status: 500 }
    );
  }
}
