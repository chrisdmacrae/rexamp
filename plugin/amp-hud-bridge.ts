// Serves the live state of your recent Amp threads on localhost for
// rex-hud, wherever each thread runs: this machine, other runners, orbs.
// Install by symlinking into ~/.config/amp/plugins/.
import type { PluginAPI, ThreadID, ThreadState } from '@ampcode/plugin'

export const description = 'Serves live state of recent Amp threads on 127.0.0.1:7789 for the rex-hud terminal HUD'

const PORT = Number(process.env.AMP_HUD_BRIDGE_PORT ?? 7789)
const LIMIT = 20
const REFRESH_MS = 30_000

type Entry = {
	id: string
	title: string
	tree: string
	updated: string
	messageCount: number
	state: ThreadState | 'unknown'
	stateAt: string
}

export default function (amp: PluginAPI) {
	const threads = new Map<string, Entry>()
	const subs = new Map<string, { unsubscribe(): void }>()
	let lastError = ''

	// Every Amp process loads system plugins, so only the first one to bind
	// the port serves; the others stay quiet.
	let server: ReturnType<typeof Bun.serve>
	try {
		server = Bun.serve({
			hostname: '127.0.0.1',
			port: PORT,
			fetch() {
				const list = [...threads.values()].sort((a, b) => b.updated.localeCompare(a.updated))
				return Response.json({ pid: process.pid, error: lastError || undefined, threads: list })
			},
		})
	} catch {
		return
	}

	async function refresh() {
		const r = await amp.$`amp threads list --json --limit ${LIMIT}`
		if (r.exitCode !== 0) {
			lastError = r.stderr.trim() || `amp threads list exited ${r.exitCode}`
			return
		}
		lastError = ''
		const list: Omit<Entry, 'state' | 'stateAt'>[] = JSON.parse(r.stdout)
		const keep = new Set(list.map((t) => t.id))
		for (const [id, sub] of subs) {
			if (!keep.has(id)) {
				sub.unsubscribe()
				subs.delete(id)
				threads.delete(id)
			}
		}
		for (const t of list) {
			const prev = threads.get(t.id)
			threads.set(t.id, { ...t, state: prev?.state ?? 'unknown', stateAt: prev?.stateAt ?? '' })
			if (subs.has(t.id)) continue
			subs.set(
				t.id,
				amp.threads.get(t.id as ThreadID).state.subscribe((state) => {
					const e = threads.get(t.id)
					if (e) threads.set(t.id, { ...e, state, stateAt: new Date().toISOString() })
				}),
			)
		}
	}

	refresh().catch((e) => (lastError = String(e)))
	const timer = setInterval(() => refresh().catch((e) => (lastError = String(e))), REFRESH_MS)

	amp.onDispose(() => {
		clearInterval(timer)
		for (const s of subs.values()) s.unsubscribe()
		server.stop(true)
	})
}
