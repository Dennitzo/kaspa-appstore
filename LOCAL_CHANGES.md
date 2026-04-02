# Local Changes
#
# Purpose: Track local modifications to upstream code to make future updates easier.
#
# Format:
# - Path
# - Date: Short description (why)
#

As of: 2026-02-08

## rusty-kaspa/bridge/src/prom.rs
- 2026-02-08: Added `/api/config` (GET/POST) and a network-hashrate fallback to read/write config via web and derive missing network hashrate from worker hashrate.

## rusty-kaspa/docker/Dockerfile.kaspad
- 2026-02-08: Switched to Alpine base and updated tooling, but kept `COPY kaspa-wasm32-sdk` for local builds.

## rusty-kaspa/docker/Dockerfile.stratum-bridge
- 2026-02-08: Changed build command to `cargo build --release -p kaspa-stratum-bridge --bin stratum-bridge` for a narrower package build.

## deploy-all.sh
- 2026-02-08: Updated to deploy the new Kaspa node and new stratum-bridge versions.

## k/vite.config.ts
- 2026-02-08: Added `allowedHosts: ['umbrel.local']` to allow local Umbrel host access.

## k/src/contexts/UserSettingsContext.tsx
- 2026-02-08: Defaulted Settings to custom node/indexer with Umbrel URLs (`custom` + `http://umbrel.local:3001`, `custom-node` + `ws://umbrel.local:17110`).
