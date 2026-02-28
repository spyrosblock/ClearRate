import { NextResponse } from 'next/server';
import { sql } from '@/lib/db';

// ─── Types for store-logs-workflow ────────────────────────────────────────

/**
 * Payload received from store-logs-workflow when a new trade is novated.
 */
interface NovatedPositionPayload {
	action: 'TradeNovated'
	tradeId: string
	tokenIdA: string
	tokenIdB: string
	partyA: string
	partyB: string
	notional: string
	fixedRateBps: string
	startDate: string
	maturityDate: string
	active: boolean
	lastNpv: string
	collateralToken: string
}

/**
 * Payload received from store-logs-workflow when a position matures.
 */
interface PositionMaturedPayload {
	action: 'PositionMatured'
	tradeId: string
}

/**
 * Union type for all possible payload actions.
 */
type DatabasePayload = NovatedPositionPayload | PositionMaturedPayload;

// ─── Helper to convert Unix timestamp to ISO date string ─────────────────

const unixTimestampToISO = (timestamp: string): string => {
	const date = new Date(Number(timestamp) * 1000)
	return date.toISOString()
}

// ─── POST Handler: Insert or Update Position Data ────────────────────────

export async function POST(request: Request) {
	try {
		const body: DatabasePayload = await request.json()

		const { action } = body

		if (action === 'TradeNovated') {
			const payload = body as NovatedPositionPayload

			// Convert Unix timestamps to ISO date strings
			const startDate = unixTimestampToISO(payload.startDate)
			const maturityDate = unixTimestampToISO(payload.maturityDate)

			// Insert new position into the database
			// Uses ON CONFLICT to handle duplicate tradeIds (upsert)
			await sql`
				INSERT INTO novated_positions (
					trade_id,
					token_id_a,
					token_id_b,
					party_a,
					party_b,
					notional,
					fixed_rate_bps,
					start_date,
					maturity_date,
					active,
					last_npv,
					collateral_token
				) VALUES (
					${payload.tradeId},
					${payload.tokenIdA},
					${payload.tokenIdB},
					${payload.partyA},
					${payload.partyB},
					${payload.notional},
					${parseInt(payload.fixedRateBps)},
					${startDate},
					${maturityDate},
					${payload.active},
					${payload.lastNpv},
					${payload.collateralToken}
				)
				ON CONFLICT (trade_id) DO UPDATE SET
					token_id_a = EXCLUDED.token_id_a,
					token_id_b = EXCLUDED.token_id_b,
					party_a = EXCLUDED.party_a,
					party_b = EXCLUDED.party_b,
					notional = EXCLUDED.notional,
					fixed_rate_bps = EXCLUDED.fixed_rate_bps,
					start_date = EXCLUDED.start_date,
					maturity_date = EXCLUDED.maturity_date,
					active = EXCLUDED.active,
					last_npv = EXCLUDED.last_npv,
					collateral_token = EXCLUDED.collateral_token,
					updated_at = NOW()
			`

			return NextResponse.json({
				status: 'success',
				message: 'Novated position stored successfully',
				tradeId: payload.tradeId,
			})
		} else if (action === 'PositionMatured') {
			const payload = body as PositionMaturedPayload

			// Update position to mark it as inactive (matured)
			const result = await sql`
				UPDATE novated_positions
				SET active = FALSE, updated_at = NOW()
				WHERE trade_id = ${payload.tradeId}
			`

			return NextResponse.json({
				status: 'success',
				message: 'Position marked as matured',
				tradeId: payload.tradeId,
			})
		}

		return NextResponse.json(
			{ error: 'Unknown action type' },
			{ status: 400 }
		)
	} catch (error) {
		console.error('Error processing novated position request:', error)
		return NextResponse.json(
			{ error: 'Failed to process novated position' },
			{ status: 500 }
		)
	}
}

// ─── GET Handler: Retrieve All Positions ──────────────────────────────────

export async function GET() {
	try {
		const rows = await sql`
			SELECT 
				id,
				trade_id,
				token_id_a,
				token_id_b,
				party_a,
				party_b,
				notional,
				fixed_rate_bps,
				start_date,
				maturity_date,
				active,
				last_npv,
				collateral_token,
				created_at,
				updated_at
			FROM novated_positions
			ORDER BY created_at DESC
		`

		return NextResponse.json(rows)
	} catch (error) {
		console.error('Error fetching novated positions:', error)
		return NextResponse.json(
			{ error: 'Failed to fetch novated positions' },
			{ status: 500 }
		)
	}
}
