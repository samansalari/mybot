import { bestEffort } from "@rakazo/logging";
import { readBodyCapped } from "./web-ssrf.js";

const MEM0_TIMEOUT_MS = 15_000;
export const MEM0_BASE_URL = "https://api.mem0.ai";

/** Search responses hold a handful of bounded memories plus small metadata. */
export const MAX_MEM0_RESPONSE_BYTES = 1024 * 1024;

/** The most memories one search asks for. */
const MAX_TOP_K = 20;

/** The most memories one listing asks for, which is the most Mem0 returns in a page. */
const MAX_LIST_SIZE = 200;

/** Longest memory content sent or read back, so one memory cannot flood a run. */
export const MAX_MEM0_CONTENT_CHARS = 10_000;

export interface Mem0Result {
  id?: string;
  memory: string;
  score: number;
  updatedAt?: string;
}

export type Mem0Response<T = void> = { ok: true; value: T } | { ok: false; error: string };

export interface Mem0ConnectionConfig {
  apiKey: string;
  fetch?: typeof globalThis.fetch;
}

function requestSignal(signal?: AbortSignal): AbortSignal {
  const timeout = AbortSignal.timeout(MEM0_TIMEOUT_MS);
  return signal ? AbortSignal.any([signal, timeout]) : timeout;
}

async function readJson(response: Response, signal: AbortSignal): Promise<unknown> {
  const declared = Number(response.headers.get("content-length") ?? 0);
  if (Number.isFinite(declared) && declared > MAX_MEM0_RESPONSE_BYTES) {
    await bestEffort("cancel unread response body", response.body?.cancel());
    throw new Error("Mem0 response is too large.");
  }
  let bytes: Uint8Array;
  try {
    bytes = await readBodyCapped(response, MAX_MEM0_RESPONSE_BYTES, signal);
  } catch (error) {
    if (error instanceof Error && error.message === "Response is too large") {
      throw new Error("Mem0 response is too large.");
    }
    throw error;
  }
  return JSON.parse(new TextDecoder().decode(bytes));
}

/**
 * One call to Mem0's hosted API. `action` names what failed in the error; a status in
 * `okStatuses` counts as success. Only a search reads its answer: writes and deletes carry
 * nothing Rakazo uses, so their body is dropped unread.
 */
async function mem0Call(
  config: Mem0ConnectionConfig,
  action: string,
  request: {
    method: "POST" | "DELETE";
    path: string;
    query?: Record<string, string>;
    body?: unknown;
    readAnswer?: boolean;
    okStatuses?: number[];
    signal?: AbortSignal;
  },
): Promise<Mem0Response<unknown>> {
  const url = new URL(request.path, MEM0_BASE_URL);
  for (const [key, value] of Object.entries(request.query ?? {})) url.searchParams.set(key, value);
  try {
    const signal = requestSignal(request.signal);
    const response = await (config.fetch ?? fetch)(url, {
      method: request.method,
      headers: {
        Authorization: `Token ${config.apiKey}`,
        ...(request.body === undefined ? {} : { "Content-Type": "application/json" }),
      },
      ...(request.body === undefined ? {} : { body: JSON.stringify(request.body) }),
      redirect: "error",
      signal,
    });
    if (!response.ok && !request.okStatuses?.includes(response.status)) {
      await bestEffort("cancel unread response body", response.body?.cancel());
      return { ok: false, error: `Mem0 ${action} failed: ${response.status}` };
    }
    if (!request.readAnswer || !response.ok) {
      await bestEffort("cancel unread response body", response.body?.cancel());
      return { ok: true, value: undefined };
    }
    return { ok: true, value: await readJson(response, signal) };
  } catch (error) {
    return {
      ok: false,
      error:
        error instanceof Error && error.message === "Mem0 response is too large."
          ? error.message
          : `Mem0 is unreachable: ${error instanceof Error ? error.message : String(error)}`,
    };
  }
}

function parseResults(data: unknown): Mem0Result[] {
  const results = (data as { results?: unknown } | null)?.results;
  if (!Array.isArray(results)) return [];
  const parsed: Mem0Result[] = [];
  for (const item of results) {
    if (!item || typeof item !== "object") continue;
    const row = item as { id?: unknown; memory?: unknown; score?: unknown; updated_at?: unknown };
    const memory = typeof row.memory === "string" ? row.memory.trim() : "";
    if (!memory) continue;
    parsed.push({
      memory: memory.slice(0, MAX_MEM0_CONTENT_CHARS),
      score: typeof row.score === "number" ? row.score : 0,
      ...(typeof row.id === "string" ? { id: row.id } : {}),
      ...(typeof row.updated_at === "string" ? { updatedAt: row.updated_at } : {}),
    });
  }
  return parsed;
}

function searchNamespace(
  query: string,
  namespace: string,
  topK: number,
  config: Mem0ConnectionConfig,
  signal?: AbortSignal,
): Promise<Mem0Response<unknown>> {
  return mem0Call(config, "search", {
    method: "POST",
    path: "/v3/memories/search/",
    body: { query, filters: { user_id: namespace }, top_k: topK },
    readAnswer: true,
    signal,
  });
}

/** Searches each namespace, then merges: the best score wins when a memory appears in several. */
export async function searchMem0Namespaces(
  query: string,
  namespaces: string[],
  config: Mem0ConnectionConfig,
  limit: number,
  signal?: AbortSignal,
): Promise<Mem0Response<Mem0Result[]>> {
  const topK = Math.min(Math.max(1, Math.floor(limit)), MAX_TOP_K);
  const responses = await Promise.all(
    namespaces.map((namespace) => searchNamespace(query, namespace, topK, config, signal)),
  );
  const errors = responses.flatMap((response) => (response.ok ? [] : [response.error]));
  // One namespace answering is enough: a failed one only means fewer memories to recall.
  if (errors.length === responses.length) return { ok: false, error: errors.join("; ") };
  const byMemory = new Map<string, Mem0Result>();
  for (const response of responses) {
    if (!response.ok) continue;
    for (const result of parseResults(response.value)) {
      const existing = byMemory.get(result.memory);
      if (!existing || result.score > existing.score) byMemory.set(result.memory, result);
    }
  }
  return {
    ok: true,
    value: [...byMemory.values()].sort((a, b) => b.score - a.score).slice(0, topK),
  };
}

/**
 * Adds the content to every namespace. Mem0 normally extracts the facts itself, after this
 * returns; `verbatim` stores the text as written, right away, for a note that is already a fact.
 */
export async function addMem0Memory(
  content: string,
  namespaces: string[],
  config: Mem0ConnectionConfig,
  verbatim: boolean,
  signal?: AbortSignal,
): Promise<Mem0Response> {
  const memory = content.trim().slice(0, MAX_MEM0_CONTENT_CHARS);
  if (!memory) return { ok: false, error: "Mem0 save skipped: memory content is empty." };
  const results = await Promise.all(
    namespaces.map(async (namespace) => ({
      namespace,
      result: await mem0Call(config, "save", {
        method: "POST",
        path: "/v3/memories/add/",
        body: {
          messages: [{ role: "user", content: memory }],
          user_id: namespace,
          ...(verbatim ? { infer: false } : {}),
        },
        signal,
      }),
    })),
  );
  const failures = results.flatMap(({ namespace, result }) =>
    result.ok ? [] : [`${namespace}: ${result.error}`],
  );
  return failures.length === 0
    ? { ok: true, value: undefined }
    : { ok: false, error: failures.join("; ") };
}

/** The newest memories in a namespace, as Mem0 stores them. */
export async function listMem0Namespace(
  namespace: string,
  config: Mem0ConnectionConfig,
  limit: number,
  signal?: AbortSignal,
): Promise<Mem0Response<Mem0Result[]>> {
  const response = await mem0Call(config, "list", {
    method: "POST",
    path: "/v3/memories/",
    query: {
      page: "1",
      page_size: String(Math.min(Math.max(1, Math.floor(limit)), MAX_LIST_SIZE)),
    },
    body: { filters: { user_id: namespace } },
    readAnswer: true,
    signal,
  });
  if (!response.ok) return response;
  const updated = (result: Mem0Result) => Date.parse(result.updatedAt ?? "") || 0;
  return { ok: true, value: parseResults(response.value).sort((a, b) => updated(b) - updated(a)) };
}

/** Deletes every memory in a namespace. One with nothing in it has nothing to delete. */
export function deleteMem0Namespace(
  namespace: string,
  config: Mem0ConnectionConfig,
  signal?: AbortSignal,
): Promise<Mem0Response<unknown>> {
  return mem0Call(config, "delete", {
    method: "DELETE",
    path: "/v3/memories/",
    query: { user_id: namespace },
    okStatuses: [404],
    signal,
  });
}

/** Checks the key by searching a namespace nothing is saved in, which touches nobody's data. */
export async function probeMem0(config: Mem0ConnectionConfig): Promise<Mem0Response> {
  const probe = await searchNamespace("connection check", "rakazo:connection-check", 1, config);
  if (probe.ok) return { ok: true, value: undefined };
  return {
    ok: false,
    error: /failed: 40[13]$/.test(probe.error) ? "Mem0 rejected the API key." : probe.error,
  };
}
