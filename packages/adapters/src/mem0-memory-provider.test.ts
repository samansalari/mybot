import type { AdapterContext } from "@rakazo/adapter-kit";
import { afterEach, describe, expect, it, vi } from "vitest";
import { MAX_MEM0_CONTENT_CHARS } from "./mem0-client.js";
import {
  createMem0Provider,
  Mem0MemoryProvider,
  prepareMem0Connection,
} from "./mem0-memory-provider.js";

const context: AdapterContext = {
  operationId: "op-1",
  traceId: "trace-1",
  spaceId: "space-1",
  userId: "user-1",
  botId: "bot-1",
  signal: new AbortController().signal,
};

const API_KEY = "m0-test-key-1234";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** Stubs fetch with an answer per call; each call gets a fresh Response. */
function stubFetch(
  answer: (url: URL, init: RequestInit) => Response = () => json({ results: [] }),
) {
  const fetchMock = vi.fn(async (url: URL, init: RequestInit) => answer(url, init));
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

function bodies(fetchMock: ReturnType<typeof stubFetch>) {
  return fetchMock.mock.calls.map(([, init]) => JSON.parse(String(init.body)));
}

const provider = () => new Mem0MemoryProvider({ apiKey: API_KEY });

afterEach(() => vi.unstubAllGlobals());

describe("Mem0MemoryProvider recall", () => {
  it("searches the bot's and the Space's namespaces with the key, and nothing else", async () => {
    const fetchMock = stubFetch();

    await provider().recall(
      { query: "project", scope: "shared", botId: "bot-1", limit: 5 },
      context,
    );

    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      "https://api.mem0.ai/v3/memories/search/",
      "https://api.mem0.ai/v3/memories/search/",
    ]);
    expect(fetchMock.mock.calls[0]?.[1].headers).toMatchObject({
      Authorization: `Token ${API_KEY}`,
    });
    expect(bodies(fetchMock)).toEqual([
      { query: "project", filters: { user_id: "rakazo:space:space-1" }, top_k: 5 },
      { query: "project", filters: { user_id: "rakazo:bot-1" }, top_k: 5 },
    ]);
  });

  it("keeps isolated recall to the bot and adds the history generation only after compaction", async () => {
    const fetchMock = stubFetch();

    await provider().recall({ query: "q", scope: "isolated", botId: "bot-1", limit: 5 }, context);
    await provider().recall(
      { query: "q", scope: "isolated", botId: "bot-1", historyGeneration: 3, limit: 5 },
      context,
    );

    expect(bodies(fetchMock).map((body) => body.filters.user_id)).toEqual([
      "rakazo:bot-1",
      "rakazo:bot-1",
      "rakazo:bot-1:history:3",
    ]);
  });

  it("merges namespaces, keeps the best score for a repeated memory, and skips blanks", async () => {
    stubFetch((_url, init) => {
      const { user_id } = JSON.parse(String(init.body)).filters;
      return user_id === "rakazo:space:space-1"
        ? json({
            results: [
              {
                id: "a",
                memory: "Use metric units.",
                score: 0.5,
                updated_at: "2026-01-01T00:00:00Z",
              },
              { id: "x", memory: "   ", score: 0.99 },
            ],
          })
        : json({
            results: [
              { id: "b", memory: "Use metric units.", score: 0.9 },
              { id: "c", memory: "Invoices go to finance.", score: 0.7 },
            ],
          });
    });

    const recalled = await provider().recall(
      { query: "units", scope: "shared", botId: "bot-1", limit: 5 },
      context,
    );

    expect(recalled).toEqual({
      ok: true,
      value: [
        { memory: "Use metric units.", score: 0.9, id: "b" },
        { memory: "Invoices go to finance.", score: 0.7, id: "c" },
      ],
    });
  });

  it("recalls what it can when one namespace fails, and fails only when all do", async () => {
    stubFetch((_url, init) =>
      JSON.parse(String(init.body)).filters.user_id === "rakazo:bot-1"
        ? json({ results: [{ memory: "Likes tea.", score: 0.8 }] })
        : json({}, 500),
    );
    const request = { query: "tea", scope: "shared", botId: "bot-1", limit: 5 } as const;
    await expect(provider().recall(request, context)).resolves.toEqual({
      ok: true,
      value: [{ memory: "Likes tea.", score: 0.8 }],
    });

    stubFetch(() => json({}, 401));
    const failed = await provider().recall(request, context);
    expect(failed).toEqual({
      ok: false,
      error: "Mem0 search failed: 401; Mem0 search failed: 401",
    });
    expect(JSON.stringify(failed)).not.toContain(API_KEY);
  });

  it("does not call Mem0 for an empty query", async () => {
    const fetchMock = stubFetch();

    await expect(
      provider().recall({ query: "  ", scope: "isolated", botId: "bot-1", limit: 5 }, context),
    ).resolves.toEqual({ ok: true, value: [] });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("bounds the number of memories asked for and passes cancellation through", async () => {
    const controller = new AbortController();
    controller.abort(new Error("cancelled"));
    const fetchMock = stubFetch();

    await provider().recall(
      { query: "q", scope: "isolated", botId: "bot-1", limit: 500 },
      { ...context, signal: controller.signal },
    );

    expect(bodies(fetchMock)[0].top_k).toBe(20);
    expect(fetchMock.mock.calls[0]?.[1].signal?.aborted).toBe(true);
  });

  it("refuses a response that declares itself too large", async () => {
    stubFetch(
      () =>
        new Response("{}", {
          status: 200,
          headers: { "content-length": String(10 * 1024 * 1024) },
        }),
    );

    await expect(
      provider().recall({ query: "q", scope: "isolated", botId: "bot-1", limit: 5 }, context),
    ).resolves.toEqual({ ok: false, error: "Mem0 response is too large." });
  });

  it("reports an unreachable service without the key", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new Error("connect ECONNREFUSED");
      }),
    );

    await expect(
      provider().recall({ query: "q", scope: "isolated", botId: "bot-1", limit: 5 }, context),
    ).resolves.toEqual({ ok: false, error: "Mem0 is unreachable: connect ECONNREFUSED" });
  });
});

describe("Mem0MemoryProvider save", () => {
  it("saves a shared durable memory to the Space and mirrors it to the bot", async () => {
    const fetchMock = stubFetch(() => json({ status: "PENDING" }));

    await expect(
      provider().save(
        {
          content: "  Use metric units.  ",
          scope: "shared",
          botId: "bot-1",
          source: { kind: "durable" },
        },
        context,
      ),
    ).resolves.toEqual({ ok: true, value: undefined });

    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      "https://api.mem0.ai/v3/memories/add/",
      "https://api.mem0.ai/v3/memories/add/",
    ]);
    expect(bodies(fetchMock)).toEqual([
      {
        messages: [{ role: "user", content: "Use metric units." }],
        user_id: "rakazo:space:space-1",
        infer: false,
      },
      {
        messages: [{ role: "user", content: "Use metric units." }],
        user_id: "rakazo:bot-1",
        infer: false,
      },
    ]);
  });

  it("saves an isolated memory to the bot only, and history to its own generation", async () => {
    const fetchMock = stubFetch();

    await provider().save(
      { content: "Fact.", scope: "isolated", botId: "bot-1", source: { kind: "durable" } },
      context,
    );
    await provider().save(
      {
        content: "Summary.",
        scope: "shared",
        botId: "bot-1",
        source: { kind: "history", generation: 2 },
      },
      context,
    );

    expect(bodies(fetchMock).map((body) => body.user_id)).toEqual([
      "rakazo:bot-1",
      "rakazo:bot-1:history:2",
    ]);
    // A note is stored as written; a long chat summary is left for Mem0 to extract facts from.
    expect(bodies(fetchMock).map((body) => body.infer)).toEqual([false, undefined]);
  });

  it("caps oversized content and refuses empty content without calling Mem0", async () => {
    const fetchMock = stubFetch();

    await provider().save(
      {
        content: "x".repeat(MAX_MEM0_CONTENT_CHARS + 50),
        scope: "isolated",
        botId: "bot-1",
        source: { kind: "durable" },
      },
      context,
    );
    expect(bodies(fetchMock)[0].messages[0].content).toHaveLength(MAX_MEM0_CONTENT_CHARS);

    fetchMock.mockClear();
    await expect(
      provider().save(
        { content: "   ", scope: "isolated", botId: "bot-1", source: { kind: "durable" } },
        context,
      ),
    ).resolves.toEqual({ ok: false, error: "Mem0 save skipped: memory content is empty." });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("names the namespace whose save failed", async () => {
    stubFetch((_url, init) =>
      JSON.parse(String(init.body)).user_id === "rakazo:bot-1" ? json({}, 429) : json({}),
    );

    await expect(
      provider().save(
        { content: "Fact.", scope: "shared", botId: "bot-1", source: { kind: "durable" } },
        context,
      ),
    ).resolves.toEqual({ ok: false, error: "rakazo:bot-1: Mem0 save failed: 429" });
  });
});

describe("Mem0MemoryProvider listShared", () => {
  it("lists the Space's pool newest first, as stored", async () => {
    const fetchMock = stubFetch(() =>
      json({
        count: 3,
        next: null,
        previous: null,
        results: [
          { id: "old", memory: "Invoices go to finance.", updated_at: "2026-01-01T00:00:00Z" },
          { id: "new", memory: "Use metric units.", updated_at: "2026-02-01T00:00:00Z" },
          { id: "blank", memory: "  " },
        ],
      }),
    );

    await expect(provider().listShared({ limit: 50 }, context)).resolves.toEqual({
      ok: true,
      value: [
        { memory: "Use metric units.", score: 0, id: "new", updatedAt: "2026-02-01T00:00:00Z" },
        {
          memory: "Invoices go to finance.",
          score: 0,
          id: "old",
          updatedAt: "2026-01-01T00:00:00Z",
        },
      ],
    });
    expect(String(fetchMock.mock.calls[0]?.[0])).toBe(
      "https://api.mem0.ai/v3/memories/?page=1&page_size=50",
    );
    expect(fetchMock.mock.calls[0]?.[1].method).toBe("POST");
    expect(bodies(fetchMock)).toEqual([{ filters: { user_id: "rakazo:space:space-1" } }]);
  });

  it("asks for no more than a page and reports a failure without the key", async () => {
    const fetchMock = stubFetch(() => json({}, 500));

    const failed = await provider().listShared({ limit: 5000 }, context);

    expect(String(fetchMock.mock.calls[0]?.[0])).toContain("page_size=200");
    expect(failed).toEqual({ ok: false, error: "Mem0 list failed: 500" });
    expect(JSON.stringify(failed)).not.toContain(API_KEY);
  });
});

describe("Mem0MemoryProvider purgeHistory", () => {
  it("deletes each history generation once, and treats a missing one as deleted", async () => {
    const fetchMock = stubFetch((url) =>
      url.searchParams.get("user_id")?.endsWith(":2") ? json({}, 404) : json({ deleted: true }),
    );

    await expect(
      provider().purgeHistory({ botId: "bot-1", generations: [1, 2, 1] }, context),
    ).resolves.toEqual({ ok: true, value: undefined });

    expect(fetchMock.mock.calls.map(([url, init]) => [init.method, String(url)])).toEqual([
      ["DELETE", "https://api.mem0.ai/v3/memories/?user_id=rakazo%3Abot-1%3Ahistory%3A1"],
      ["DELETE", "https://api.mem0.ai/v3/memories/?user_id=rakazo%3Abot-1%3Ahistory%3A2"],
    ]);
  });

  it("reports a failed delete", async () => {
    stubFetch(() => json({}, 500));

    await expect(
      provider().purgeHistory({ botId: "bot-1", generations: [1] }, context),
    ).resolves.toEqual({ ok: false, error: "Mem0 delete failed: 500" });
  });
});

describe("Mem0 provider description", () => {
  it("is searched before every run, which makes it the bot's main memory", () => {
    expect(provider().describe()).toMatchObject({
      id: "mem0",
      capabilities: { recall: true, save: true, purgeHistory: true, recallEachRun: true },
    });
  });
});

describe("Mem0 connection", () => {
  it("checks the key before saving it, and stores nothing but the key", async () => {
    const fetchMock = vi.fn(async () => json({ results: [] }));

    await expect(
      prepareMem0Connection({ apiKey: ` ${API_KEY} ` }, { fetch: fetchMock as never }),
    ).resolves.toEqual({ settings: {}, credentials: { apiKey: API_KEY } });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("turns a rejected key down in plain words", async () => {
    const fetchMock = vi.fn(async () => json({}, 401));

    await expect(
      prepareMem0Connection({ apiKey: API_KEY }, { fetch: fetchMock as never }),
    ).rejects.toThrow("Mem0 rejected the API key.");
  });

  it("refuses a missing or short key without calling Mem0", async () => {
    const fetchMock = vi.fn();

    await expect(prepareMem0Connection({}, { fetch: fetchMock as never })).rejects.toThrow(
      "apiKey is required",
    );
    await expect(
      prepareMem0Connection({ apiKey: "short" }, { fetch: fetchMock as never }),
    ).rejects.toThrow("apiKey must contain at least 8 characters");
    expect(fetchMock).not.toHaveBeenCalled();
    expect(() => createMem0Provider({})).toThrow("apiKey is required");
  });
});
