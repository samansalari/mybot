import type {
  AdapterContext,
  DurableMemoryScope,
  SemanticMemoryListSharedRequest,
  SemanticMemoryProvider,
  SemanticMemoryRecallRequest,
  SemanticMemoryResponse,
  SemanticMemoryResult,
  SemanticMemorySaveRequest,
} from "@rakazo/adapter-kit";
import type { Mem0ConnectionConfig } from "./mem0-client.js";
import {
  addMem0Memory,
  deleteMem0Namespace,
  listMem0Namespace,
  probeMem0,
  searchMem0Namespaces,
} from "./mem0-client.js";
import { MEMORY_SECRET_MIN_LENGTH } from "./memory-provider-descriptor.js";

export const MEM0_PROVIDER_ID = "mem0";

function parseMem0Connection(credentials: Record<string, string>): Mem0ConnectionConfig {
  const apiKey = credentials.apiKey?.trim();
  if (!apiKey) throw new Error("apiKey is required");
  if (apiKey.length < MEMORY_SECRET_MIN_LENGTH) {
    throw new Error(`apiKey must contain at least ${MEMORY_SECRET_MIN_LENGTH} characters`);
  }
  return { apiKey };
}

/** Checks the key against Mem0 before it is saved, and stores nothing but the key. */
export async function prepareMem0Connection(
  credentials: Record<string, string>,
  options?: { fetch?: typeof globalThis.fetch },
): Promise<{ settings: Record<string, string>; credentials: Record<string, string> }> {
  const connection = { ...parseMem0Connection(credentials), fetch: options?.fetch };
  const probe = await probeMem0(connection);
  if (!probe.ok) throw new Error(probe.error);
  return { settings: {}, credentials: { apiKey: connection.apiKey } };
}

export function createMem0Provider(credentials: Record<string, string>): SemanticMemoryProvider {
  return new Mem0MemoryProvider(parseMem0Connection(credentials));
}

// Mem0 keeps memories per `user_id`. These names are Rakazo's own namespaces inside one Mem0
// project: one per bot, one per Space for the memory its bots share, and one per history
// generation so a cleared chat can be deleted whole.
function spaceNamespace(spaceId: string): string {
  return `rakazo:space:${spaceId}`;
}

function durableNamespaces(scope: DurableMemoryScope, botId: string, spaceId: string): string[] {
  const isolated = `rakazo:${botId}`;
  return scope === "shared" ? [spaceNamespace(spaceId), isolated] : [isolated];
}

function historyNamespace(botId: string, generation: number): string {
  return `rakazo:${botId}:history:${generation}`;
}

function recallNamespaces(request: SemanticMemoryRecallRequest, spaceId: string): string[] {
  const namespaces = durableNamespaces(request.scope, request.botId, spaceId);
  return request.historyGeneration === undefined
    ? namespaces
    : [...namespaces, historyNamespace(request.botId, request.historyGeneration)];
}

export class Mem0MemoryProvider implements SemanticMemoryProvider {
  constructor(private readonly connection: Mem0ConnectionConfig) {}

  describe() {
    return {
      id: MEM0_PROVIDER_ID,
      contractVersion: "1",
      adapterVersion: "0.1.0",
      capabilities: {
        recall: true,
        save: true,
        purgeHistory: true,
        sharedScope: true,
        // Mem0 is the bot's main memory: it is searched before every run, not only after
        // a long chat has been compacted.
        recallEachRun: true,
      } as const,
    };
  }

  async recall(
    request: SemanticMemoryRecallRequest,
    context: AdapterContext,
  ): Promise<SemanticMemoryResponse<SemanticMemoryResult[]>> {
    // Mem0 rejects an empty search query.
    if (!request.query.trim()) return { ok: true, value: [] };
    const result = await searchMem0Namespaces(
      request.query,
      recallNamespaces(request, context.spaceId),
      this.connection,
      request.limit,
      context.signal,
    );
    return result.ok
      ? {
          ok: true,
          value: result.value.slice(0, request.limit).map(({ id, memory, score, updatedAt }) => ({
            memory,
            score,
            ...(id ? { id } : {}),
            ...(updatedAt ? { updatedAt } : {}),
          })),
        }
      : result;
  }

  save(
    request: SemanticMemorySaveRequest,
    context: AdapterContext,
  ): Promise<SemanticMemoryResponse> {
    return addMem0Memory(
      request.content,
      request.source.kind === "history"
        ? [historyNamespace(request.botId, request.source.generation)]
        : durableNamespaces(request.scope, request.botId, context.spaceId),
      this.connection,
      // A saved note is already one fact: storing it as written is immediate, and it reads back
      // exactly as the bot wrote it. Chat summaries are long, so Mem0 extracts their facts.
      request.source.kind === "durable",
      context.signal,
    );
  }

  async listShared(
    request: SemanticMemoryListSharedRequest,
    context: AdapterContext,
  ): Promise<SemanticMemoryResponse<SemanticMemoryResult[]>> {
    const result = await listMem0Namespace(
      spaceNamespace(context.spaceId),
      this.connection,
      request.limit,
      context.signal,
    );
    return result.ok
      ? {
          ok: true,
          value: result.value.map(({ id, memory, score, updatedAt }) => ({
            memory,
            score,
            ...(id ? { id } : {}),
            ...(updatedAt ? { updatedAt } : {}),
          })),
        }
      : result;
  }

  async purgeHistory(
    request: { botId: string; generations: number[] },
    context: AdapterContext,
  ): Promise<SemanticMemoryResponse> {
    const results = await Promise.all(
      [...new Set(request.generations)].map((generation) =>
        deleteMem0Namespace(
          historyNamespace(request.botId, generation),
          this.connection,
          context.signal,
        ),
      ),
    );
    const errors = results.flatMap((result) => (result.ok ? [] : [result.error]));
    return errors.length > 0
      ? { ok: false, error: errors.join("; ") }
      : { ok: true, value: undefined };
  }
}
