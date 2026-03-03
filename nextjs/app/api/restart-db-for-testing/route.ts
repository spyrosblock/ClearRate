import { NextResponse } from 'next/server';
import { sql } from '@/lib/db';

/**
 * Restart DB for Testing API
 * 
 * This endpoint deletes all data from all tables (but keeps the tables themselves).
 * Used for testing purposes to reset the database to a clean state.
 * 
 * GET /api/restart-db-for-testing
 * 
 * Response:
 * {
 *   success: boolean,
 *   message: string,
 *   tablesCleared: string[]
 * }
 */
export async function GET() {
  try {
    console.log('[Restart DB API] Starting database reset...');
    
    const tablesCleared: string[] = [];
    
    // Clear novated_positions table
    try {
      await sql`TRUNCATE TABLE novated_positions RESTART IDENTITY CASCADE`;
      tablesCleared.push('novated_positions');
      console.log('[Restart DB API] Cleared novated_positions table');
    } catch (error) {
      console.error('[Restart DB API] Error clearing novated_positions:', error);
      // Continue with other tables even if one fails
    }
    
    // Clear users table
    try {
      await sql`TRUNCATE TABLE users RESTART IDENTITY CASCADE`;
      tablesCleared.push('users');
      console.log('[Restart DB API] Cleared users table');
    } catch (error) {
      console.error('[Restart DB API] Error clearing users:', error);
      // Continue even if this fails
    }
    
    // Clear liquidation_monitoring table
    try {
      await sql`TRUNCATE TABLE liquidation_monitoring RESTART IDENTITY CASCADE`;
      tablesCleared.push('liquidation_monitoring');
      console.log('[Restart DB API] Cleared liquidation_monitoring table');
    } catch (error) {
      console.error('[Restart DB API] Error clearing liquidation_monitoring:', error);
      // Continue even if this fails
    }
    
    console.log('[Restart DB API] Database reset completed');
    console.log('[Restart DB API] Tables cleared:', tablesCleared);
    
    return NextResponse.json({
      success: true,
      message: 'Database reset completed successfully',
      tablesCleared
    });
    
  } catch (error) {
    console.error('[Restart DB API] Error resetting database:', error);
    return NextResponse.json(
      { success: false, message: 'Failed to reset database' },
      { status: 500 }
    );
  }
}
