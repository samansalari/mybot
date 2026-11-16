import { MEM0_PROVIDER_ID } from "./mem0-memory-provider.js";
import type { SettingsMemoryProvider } from "./memory-provider-descriptor.js";
import { MEMORY_SECRET_MIN_LENGTH } from "./memory-provider-descriptor.js";

export const mem0MemorySettings: SettingsMemoryProvider = {
  id: MEM0_PROVIDER_ID,
  displayName: "Mem0",
  fields: [
    {
      key: "apiKey",
      label: "API key",
      kind: "secret",
      required: true,
      placeholder: "m0-…",
      minLength: MEMORY_SECRET_MIN_LENGTH,
    },
  ],
  connectionLabel: () => "Mem0 Cloud",
};
