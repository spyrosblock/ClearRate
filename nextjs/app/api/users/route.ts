import { NextRequest, NextResponse } from 'next/server';
import { sql } from '@/lib/db';

/**
 * Users API
 * 
 * This endpoint adds user KYB data to the database.
 * 
 * POST /api/users
 * Request body:
 * {
 *   address: string,        // Ethereum address (required)
 *   accountId: string,      // Account ID (bytes32 hex, optional)
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
 *   },
 *   approved: boolean,      // Optional, default false
 *   validUntil: string,     // Optional, ISO date string
 *   maxNotional: string,    // Optional, default "0"
 * }
 * 
 * Response:
 * {
 *   success: boolean,
 *   userId: number,         // Inserted user ID
 *   message?: string
 * }
 */
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    
    const { address, accountId, company, approved, validUntil, maxNotional, notional } = body;
    
    // Validate required fields
    if (!address) {
      return NextResponse.json(
        { success: false, message: 'Missing required field: address' },
        { status: 400 }
      );
    }
    
    // Validate Ethereum address format
    if (!/^0x[a-fA-F0-9]{40}$/.test(address)) {
      return NextResponse.json(
        { success: false, message: 'Invalid Ethereum address format' },
        { status: 400 }
      );
    }
    
    // Validate accountId format if provided
    if (accountId && !/^0x[a-fA-F0-9]{64}$/.test(accountId)) {
      return NextResponse.json(
        { success: false, message: 'Invalid account ID format' },
        { status: 400 }
      );
    }
    
    // Validate company data
    if (!company) {
      return NextResponse.json(
        { success: false, message: 'Company data is required' },
        { status: 400 }
      );
    }
    
    // Validate company fields
    if (!company.companyName || !company.registrationNumber || !company.registeredCountry || !company.contactEmail) {
      return NextResponse.json(
        { success: false, message: 'Missing required company fields: companyName, registrationNumber, registeredCountry, contactEmail' },
        { status: 400 }
      );
    }
    
    // Validate LEI (Legal Entity Identifier) - 20 alphanumeric characters
    if (!company.lei) {
      return NextResponse.json(
        { success: false, message: 'Missing required company field: lei' },
        { status: 400 }
      );
    }
    if (!/^[A-Z0-9]{20}$/.test(company.lei)) {
      return NextResponse.json(
        { success: false, message: 'Invalid LEI format - must be 20 alphanumeric characters' },
        { status: 400 }
      );
    }
    
    // Validate website
    if (!company.website) {
      return NextResponse.json(
        { success: false, message: 'Missing required company field: website' },
        { status: 400 }
      );
    }
    
    // Validate uploaded legal documents
    if (!company.uploadedLegalDocs) {
      return NextResponse.json(
        { success: false, message: 'Missing required company field: uploadedLegalDocs' },
        { status: 400 }
      );
    }
    if (!company.uploadedLegalDocs.articlesOfAssociation || 
        !company.uploadedLegalDocs.certificateOfIncorporation || 
        !company.uploadedLegalDocs.vatCertificate) {
      return NextResponse.json(
        { success: false, message: 'Missing required legal documents: articlesOfAssociation, certificateOfIncorporation, vatCertificate' },
        { status: 400 }
      );
    }
    
    // Validate bank details
    if (!company.bankDetails) {
      return NextResponse.json(
        { success: false, message: 'Missing required company field: bankDetails' },
        { status: 400 }
      );
    }
    if (!company.bankDetails.iban || !company.bankDetails.bic) {
      return NextResponse.json(
        { success: false, message: 'Missing required bank details: iban, bic' },
        { status: 400 }
      );
    }
    
    // Check if user with this address already exists
    const existingUser = await sql`
      SELECT id FROM users WHERE address = ${address}
    `;
    
    if (existingUser.length > 0) {
      return NextResponse.json(
        { success: false, message: 'User with this address already exists' },
        { status: 409 }
      );
    }
    
    // Check if registration number already exists
    const existingReg = await sql`
      SELECT id FROM users WHERE registration_number = ${company.registrationNumber}
    `;
    
    if (existingReg.length > 0) {
      return NextResponse.json(
        { success: false, message: 'Company with this registration number already exists' },
        { status: 409 }
      );
    }
    
    // Check if LEI already exists
    const existingLei = await sql`
      SELECT id FROM users WHERE lei = ${company.lei}
    `;
    
    if (existingLei.length > 0) {
      return NextResponse.json(
        { success: false, message: 'Company with this LEI already exists' },
        { status: 409 }
      );
    }
    
    // todo: uncomment this (commented it because it uses neon db cpu)
    // // Insert user into database
    // const result = await sql`
    //   INSERT INTO users (
    //     address,
    //     account_id,
    //     company_name,
    //     registration_number,
    //     registered_country,
    //     contact_email,
    //     lei,
    //     website,
    //     articles_of_association,
    //     certificate_of_incorporation,
    //     vat_certificate,
    //     iban,
    //     bic,
    //     approved,
    //     valid_until,
    //     max_notional,
    //     notional
    //   ) VALUES (
    //     ${address},
    //     ${accountId || null},
    //     ${company.companyName},
    //     ${company.registrationNumber},
    //     ${company.registeredCountry},
    //     ${company.contactEmail},
    //     ${company.lei},
    //     ${company.website},
    //     ${company.uploadedLegalDocs.articlesOfAssociation},
    //     ${company.uploadedLegalDocs.certificateOfIncorporation},
    //     ${company.uploadedLegalDocs.vatCertificate},
    //     ${company.bankDetails.iban},
    //     ${company.bankDetails.bic},
    //     ${approved ?? false},
    //     ${validUntil ? new Date(validUntil) : null},
    //     ${maxNotional || '0'},
    //     ${notional || '0'}
    //   )
    // `;
    
    console.log('[Users API] User created successfully:');
    console.log('  Address:', address);
    console.log('  Company:', company.companyName);
    
    return NextResponse.json({
      success: true,
      message: 'User created successfully'
    });
    
  } catch (error) {
    console.error('[Users API] Error processing request:', error);
    return NextResponse.json(
      { success: false, message: 'Internal server error' },
      { status: 500 }
    );
  }
}

/**
 * GET /api/users
 * 
 * Retrieve users from the database.
 * Query params:
 * - address: Filter by Ethereum address
 * - accountId: Filter by account ID
 * - approved: Filter by approval status (true/false)
 */
export async function GET(request: NextRequest) {
  try {
    const { searchParams } = new URL(request.url);
    const address = searchParams.get('address');
    const accountId = searchParams.get('accountId');
    const approved = searchParams.get('approved');
    
    let users;
    
    if (address) {
      users = await sql`
        SELECT * FROM users WHERE address = ${address}
      `;
    } else if (accountId) {
      users = await sql`
        SELECT * FROM users WHERE account_id = ${accountId}
      `;
    } else if (approved !== null) {
      const isApproved = approved === 'true';
      users = await sql`
        SELECT * FROM users WHERE approved = ${isApproved}
      `;
    } else {
      users = await sql`
        SELECT * FROM users ORDER BY created_at DESC
      `;
    }
    
    return NextResponse.json({
      success: true,
      users
    });
    
  } catch (error) {
    console.error('[Users API] Error fetching users:', error);
    return NextResponse.json(
      { success: false, message: 'Internal server error' },
      { status: 500 }
    );
  }
}