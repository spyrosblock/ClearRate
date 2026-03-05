import { NextResponse } from 'next/server';
import { sql } from '@/lib/db';

// ─── Types for position-matured API ────────────────────────────────────────

/**
 * Payload received when a position matures.
 */
interface PositionMaturedPayload {
	tokenId: string,
	accountId: string
}

// ─── POST Handler: Mark Position as Matured ────────────────────────────────

export async function POST(request: Request) {
	try {
		const body: PositionMaturedPayload = await request.json()

		const { tokenId, accountId } = body

		// Update position to mark it as inactive (matured)
		const result = await sql`
			UPDATE swap_positions
			SET active = FALSE, updated_at = NOW()
			WHERE 
        		token_id = ${tokenId}
        		AND owner_id = ${accountId}
			RETURNING id, token_id
		`

		return NextResponse.json({
			status: 'success',
			message: 'Position marked as matured',
			tokenId: tokenId,
			updated: result.length > 0,
		})
	} catch (error) {
		console.error('Error processing position matured request:', error)
		return NextResponse.json(
			{ error: 'Failed to mark position as matured' },
			{ status: 500 }
		)
	}
}
