import { describe, expect, it, vi } from "vitest"

import type { HealthResponse } from "./api"
import { activeRequests, probeEngineOrigin, supportsCacheSlots } from "./runtime"

const healthWithActive = (active: boolean | number): HealthResponse => ({
  status: "ok",
  scheduler: {
    active,
    queued: 0,
    max_queue: 0,
    queue_timeout_seconds: 0,
    admitted: 0,
    completed: 0,
    rejected: 0,
    timed_out: 0,
    cancelled: 0,
  },
})

describe("runtime capability normalization", () => {
  it.each([
    [true, 1],
    [false, 0],
    [3, 3],
    [0, 0],
  ] as const)("normalizes scheduler.active %s to %d", (active, expected) => {
    expect(activeRequests(healthWithActive(active))).toBe(expected)
  })

  it("treats missing scheduler metrics as idle", () => {
    expect(activeRequests({ status: "ok" })).toBe(0)
    expect(activeRequests(null)).toBe(0)
  })

  it("only enables cache slots when the health response advertises them", () => {
    expect(supportsCacheSlots({ status: "ok", kv_slots: 4 })).toBe(true)
    expect(supportsCacheSlots({ status: "ok" })).toBe(false)
    expect(supportsCacheSlots(null)).toBe(false)
  })
})

describe("probeEngineOrigin", () => {
  it("resolves true for a genuine engine health response", async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({ status: "ok", kv_slots: 2 })))
    await expect(probeEngineOrigin("http://localhost:8000", fetchMock)).resolves.toBe(true)
    expect(fetchMock).toHaveBeenCalledWith("http://localhost:8000/health", expect.anything())
  })

  it("resolves false on an HTTP failure (e.g. 404 from a static server)", async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response("not found", { status: 404 }))
    await expect(probeEngineOrigin("http://localhost:5173", fetchMock)).resolves.toBe(false)
  })

  it("resolves false for a malformed/non-engine response body", async () => {
    // e.g. a Vite dev/preview server serving its index.html fallback for an
    // unknown path with a 200 status: not JSON, so response.json() throws.
    const htmlFetch = vi.fn().mockResolvedValue(new Response("<!doctype html><html></html>", { status: 200 }))
    await expect(probeEngineOrigin("http://localhost:5173", htmlFetch)).resolves.toBe(false)

    // Valid JSON, but missing the `status` field an engine health payload
    // always has.
    const wrongShapeFetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({ hello: "world" })))
    await expect(probeEngineOrigin("http://localhost:4173", wrongShapeFetch)).resolves.toBe(false)
  })

  it("resolves false on a network error", async () => {
    const fetchMock = vi.fn().mockRejectedValue(new TypeError("Failed to fetch"))
    await expect(probeEngineOrigin("http://localhost:9999", fetchMock)).resolves.toBe(false)
  })
})
