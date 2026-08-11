import type { HealthResponse } from "./api"
import { serverEndpoint } from "./api"

export function activeRequests(health: HealthResponse | null): number {
  return Number(health?.scheduler?.active || 0)
}

export function supportsCacheSlots(health: HealthResponse | null): boolean {
  return typeof health?.kv_slots === "number" && health.kv_slots > 0
}

// The endpoint used when no same-origin engine is detected: colibrì's own
// default local server address.
export const DEFAULT_ENGINE_BASE_URL = "http://127.0.0.1:8000/v1"

export type FetchLike = typeof fetch

// Narrows an unknown JSON body down to "looks like a colibrì /health
// response" — specifically, an object with a string `status` field. This is
// intentionally loose about the rest of the shape (scheduler/kv_slots/etc.
// are all optional) but strict enough that arbitrary JSON (or HTML parsed as
// text, which throws before this check even runs) won't pass.
function looksLikeEngineHealth(body: unknown): body is HealthResponse {
  return !!body && typeof body === "object" && typeof (body as Record<string, unknown>).status === "string"
}

// Determines whether `origin` is actually serving the colibrì OpenAI-compatible
// engine — not just a static file server on the same machine — by probing its
// health endpoint. This replaces the old "any port other than Vite's own
// dev/preview ports" heuristic: `vite dev` (5173) and `vite preview` (4173,
// or any other port a user picks) serve byte-identical static files and have
// no way to be told apart from the bundle alone, but neither has a real
// engine behind it, so their health probe reliably fails (network error, a
// 404, or an HTML document that isn't valid JSON) regardless of port.
export async function probeEngineOrigin(
  origin: string,
  fetchImpl: FetchLike = fetch,
  signal?: AbortSignal,
): Promise<boolean> {
  try {
    const response = await fetchImpl(serverEndpoint(`${origin}/v1`, "health"), { signal })
    if (!response.ok) return false
    const body: unknown = await response.json()
    return looksLikeEngineHealth(body)
  } catch {
    // Network error (nothing listening), non-JSON body (e.g. a static
    // server's index.html fallback), or an aborted probe all mean "not an
    // engine" rather than a hard failure.
    return false
  }
}
