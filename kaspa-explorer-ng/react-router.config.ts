import type { Config } from "@react-router/dev/config";

export default {
  // Keep SSR enabled so `react-router build` emits `/build/server/index.js`,
  // which matches the container start command (`react-router-serve`).
  ssr: true,
} satisfies Config;
