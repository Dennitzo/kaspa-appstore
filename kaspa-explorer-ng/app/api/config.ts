type ExplorerRuntimeConfig = {
  apiBase?: string;
  socketUrl?: string;
  socketPath?: string;
  networkId?: string;
  apiSource?: ExplorerApiSource;
};

type ExplorerApiSource = "self-hosted" | "custom";

const readQueryConfig = (): ExplorerRuntimeConfig => {
  if (typeof window === "undefined") return {};
  const params = new URLSearchParams(window.location.search);
  const config: ExplorerRuntimeConfig = {};
  const apiBase = params.get("apiBase");
  const socketUrl = params.get("socketUrl");
  const socketPath = params.get("socketPath");
  const networkId = params.get("networkId");
  if (apiBase) config.apiBase = apiBase;
  if (socketUrl) config.socketUrl = socketUrl;
  if (socketPath) config.socketPath = socketPath;
  if (networkId) config.networkId = networkId;
  return config;
};

const QUERY_CONFIG = readQueryConfig();

type ExplorerEnvConfig = {
  VITE_KASPA_API_BASE?: string;
  VITE_KASPA_SOCKET_URL?: string;
  VITE_KASPA_SOCKET_PATH?: string;
  VITE_KASPA_NETWORK_ID?: string;
};

const readEnvConfig = (): ExplorerRuntimeConfig => {
  const env = (import.meta as { env?: ExplorerEnvConfig }).env ?? {};
  const config: ExplorerRuntimeConfig = {};
  if (env.VITE_KASPA_API_BASE) config.apiBase = env.VITE_KASPA_API_BASE;
  if (env.VITE_KASPA_SOCKET_URL) config.socketUrl = env.VITE_KASPA_SOCKET_URL;
  if (env.VITE_KASPA_SOCKET_PATH) config.socketPath = env.VITE_KASPA_SOCKET_PATH;
  if (env.VITE_KASPA_NETWORK_ID) config.networkId = env.VITE_KASPA_NETWORK_ID;
  return config;
};

const ENV_CONFIG = readEnvConfig();

const readRuntimeConfig = (): ExplorerRuntimeConfig => {
  const runtime =
    (globalThis as { __KASPA_EXPLORER_CONFIG__?: ExplorerRuntimeConfig })
      .__KASPA_EXPLORER_CONFIG__ ?? {};
  return {
    ...ENV_CONFIG,
    ...QUERY_CONFIG,
    ...runtime,
  };
};

const normalizeBase = (value: string) => value.replace(/\/+$/, "");
const normalizeSocketUrl = (value: string) => {
  const normalized = normalizeBase(value);
  if (normalized.startsWith("wss://")) return `https://${normalized.slice("wss://".length)}`;
  if (normalized.startsWith("ws://")) return `http://${normalized.slice("ws://".length)}`;
  return normalized;
};

const DEFAULT_API_BASE = "http://umbrel.local:8091";
const DEFAULT_SOCKET_URL = "http://umbrel.local:8092";

export const getApiBase = () => normalizeBase(readRuntimeConfig().apiBase ?? DEFAULT_API_BASE);
export const getSocketUrl = () => normalizeSocketUrl(readRuntimeConfig().socketUrl ?? DEFAULT_SOCKET_URL);
export const getSocketPath = () => readRuntimeConfig().socketPath ?? "/ws/socket.io";
export const getNetworkId = () => readRuntimeConfig().networkId ?? "mainnet";
export const getApiSource = (): ExplorerApiSource => {
  const runtimeSource = readRuntimeConfig().apiSource;
  if (runtimeSource) return runtimeSource;

  const apiBase = getApiBase();
  try {
    const url = new URL(apiBase);
    const host = url.hostname.toLowerCase();
    if (host === "127.0.0.1" || host === "localhost" || host === "::1") {
      return "self-hosted";
    }
  } catch {
    // Fall through to default.
  }

  return apiBase === DEFAULT_API_BASE ? "self-hosted" : "custom";
};

export const getApiSourceLabel = () => {
  const source = getApiSource();
  if (source === "self-hosted") return "Self-hosted";
  return "Custom";
};

export const getApiDisplay = () => {
  const apiBase = getApiBase();
  try {
    const url = new URL(apiBase);
    return `${url.host}${url.pathname === "/" ? "" : url.pathname}`;
  } catch {
    return apiBase;
  }
};

// Backward compatibility for modules that still import constants.
export const API_BASE = getApiBase();
export const SOCKET_URL = getSocketUrl();
export const SOCKET_PATH = getSocketPath();
export const NETWORK_ID = getNetworkId();
