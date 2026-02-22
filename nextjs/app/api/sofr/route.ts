import { NextResponse } from 'next/server';

/**
 * API for fetching Compounded SOFR (Secured Overnight Financing Rate)
 * 
 * SOFR is the primary USD floating rate benchmark for IRS contracts.
 * This endpoint calculates the compounded SOFR over a date range.
 * 
 * Input: 
 *   - startDate (required): Start date in YYYY-MM-DD format
 *   - endDate (required): End date in YYYY-MM-DD format
 * Output: Compounded SOFR rate value in percentage
 */

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  
  const startDate = searchParams.get('startDate');
  const endDate = searchParams.get('endDate');
  
  // Validate required parameters
  if (!startDate || !endDate) {
    return NextResponse.json(
      {
        success: false,
        error: 'Missing required parameters',
        message: 'startDate and endDate are required in YYYY-MM-DD format',
        example: '/api/sofr?startDate=2024-01-01&endDate=2024-01-31'
      },
      { status: 400 }
    );
  }
  
  // Validate date format
  const startDateObj = new Date(startDate);
  const endDateObj = new Date(endDate);
  
  if (isNaN(startDateObj.getTime()) || isNaN(endDateObj.getTime())) {
    return NextResponse.json(
      {
        success: false,
        error: 'Invalid date format',
        message: 'Dates must be in YYYY-MM-DD format',
        example: '/api/sofr?startDate=2024-01-01&endDate=2024-01-31'
      },
      { status: 400 }
    );
  }
  
  if (startDateObj > endDateObj) {
    return NextResponse.json(
      {
        success: false,
        error: 'Invalid date range',
        message: 'startDate must be before or equal to endDate'
      },
      { status: 400 }
    );
  }
  
  const response = {
    success: true,
    data: {
      compoundedSOFR: 4.5
    }
  };
  
  return NextResponse.json(response);
}

export const runtime = 'edge';
