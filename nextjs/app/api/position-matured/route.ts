import { NextResponse } from 'next/server';
import { sql } from '@/lib/db';

// ─── Types for position-matured API ────────────────────────────────────────

/**
 * Payload received when a position matures.
 */
interface PositionMaturedPayload {
	tokenId: string
	accountId: string
	newMM: string
}

// ─── POST Handler: Mark Position as Matured ────────────────────────────────

export async function POST(request: Request) {
	try {
		const body: PositionMaturedPayload = await request.json()

		const { tokenId, accountId, newMM } = body

		// Update position to mark it as inactive (matured)
		const result = await sql`
			UPDATE swap_positions
			SET active = FALSE, updated_at = NOW()
			WHERE token_id = ${tokenId}
			RETURNING id, token_id, collateral_token
		`

		// Update maintenance margin for the account if accountId and newMM are provided
		if (accountId && newMM !== undefined && result.length > 0) {
			const collateralToken = result[0].collateral_token
			await sql`
				INSERT INTO liquidation_monitoring (account_id, total_collateral, maintenance_margin, collateral_token)
				VALUES (${accountId}, 0, ${newMM}::numeric, ${collateralToken})
				ON CONFLICT (account_id, collateral_token) 
				DO UPDATE SET 
					maintenance_margin = ${newMM}::numeric,
					updated_at = NOW()
			`
		}

		return NextResponse.json({
			status: 'success',
			message: 'Position marked as matured',
			tokenId: tokenId,
			accountId: accountId,
			newMM: newMM,
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
