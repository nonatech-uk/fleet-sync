# fleet-sync hardening roadmap

MVP (today) is bearer-token over WG with atomic-apply-with-rollback. Good
enough for observability-class configs (alloy). Higher-trust configs
(mcp-host-tools command allowlists, future secrets-adjacent material)
need incremental hardening.

## Tier 1 — MVP (shipped)

- Per-host bearer tokens, stored 0400 on each host.
- Server bound to WireGuard interface only; iptables limits :8443 to
  WG subnets.
- Scoped tokens (fnmatch globs against content paths).
- Atomic apply: staging → validate → swap → reload → rollback on fail.
- Hourly timer + healthcheck ping for drift detection.

## Tier 2 — signed manifests (required before onboarding mcp-host-tools)

Problem Tier 1 does not solve: compromise of the hub alone can push
arbitrary content. For configs that authorise command execution, we want
cryptographic separation between *storage* and *authorisation*.

Design sketch:
- Generate an Ed25519 signing key pair. Private key held offline (USB,
  YubiKey, password manager). Public key baked into each client's install.
- On a commit to the content repo, the editor (a human, with the key)
  signs a manifest listing SHA-256 of every file, timestamp, version.
- Server serves `<service>/manifest.sig` and `<service>/manifest.json`
  alongside files.
- Client fetches manifest + signature first, verifies signature against
  pinned public key, then fetches each file and verifies SHA-256 matches
  the manifest before applying.
- Server compromise alone can serve stale content but cannot forge new
  content. Replay is mitigated by timestamp + manifest version check.

Implementation notes:
- `minisign` (the binary) works standalone, no library dependency.
- Keep tooling stupid: `fleet-sign.sh` on the editor's workstation wraps
  `minisign -Sm manifest.json`.
- Include the signing date in the manifest to defend against "freeze
  time" replay (client refuses manifests older than N days unless the
  operator explicitly acks).

## Tier 3 — OIDC short-lived tokens

Problem Tier 2 does not solve: leaked long-lived bearer token allows
indefinite read until discovery + rotation.

Design sketch:
- Use the existing Keycloak at `kc.mees.st` — each host is a
  `client_credentials` OIDC client.
- Client obtains a 1-hour access token before each sync, presents it
  to the config server, which introspects against Keycloak.
- Token rotation is automatic. Revocation is immediate (disable the
  client in Keycloak).
- Server still enforces scope; OIDC gives us identity + revocation.

Implementation notes:
- Move the auth middleware in `fleet_config_server.py` behind an
  interface so Bearer and OIDC can coexist during migration.
- Hosts that can't reach Keycloak (Keycloak on nas, so intra-WG is
  fine) fall back to static bearer. Plan a chicken-and-egg fallback
  for the nas host itself.

## Tier 4 — multi-hub / high availability

Not planned. If nas is down, the fleet runs last-applied config and
that's acceptable for a ~6-host homelab. Document `sync-if-stale`
alerts via healthcheck: if a host hasn't synced in 24h, page.

## Deliberate non-goals

- Push semantics. Hosts pull, always. A compromised hub cannot
  actively push — it can only wait for the next pull.
- Secrets distribution. Different threat model. Use podman secrets,
  sops, or a dedicated secrets manager. Do not be tempted to bolt
  encryption onto this channel.
- Public exposure. If a fleet member lives outside the WG, either (a)
  put it on WG, or (b) give it an SSH-pull mechanism backed by a deploy
  key + the same manifest format. Never open the HTTP server publicly.
