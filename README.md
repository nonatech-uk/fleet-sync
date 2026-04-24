# fleet-sync

A minimal, WireGuard-local config distribution mechanism for a small fleet.
A hub host serves per-host config bundles over HTTP; clients pull on a
timer, validate, apply atomically, reload their services, and ping
a healthcheck. Built for one person managing ~6 hosts; not trying to
compete with Ansible, SaltStack or a commercial fleet platform.

## Design goals

- No third-party runtime dependency. Python stdlib + curl + bash.
- Private by design — server binds to the WireGuard interface(s) only.
- Content and mechanism are separate repos (content lives in a sibling
  repo like `fleet-config`).
- Atomic apply with automatic rollback on reload failure.
- No secrets in the content repo. Secrets flow via a separate
  rotation-aware mechanism (podman secrets, sops, etc.).

## Threat model (what this protects against and what it does not)

**Protects against**
- Passive eavesdropping on the pull (WireGuard handles transport).
- Accidental cross-host config leaks (per-host tokens, scope-limited).
- Reload of a broken config (validate + atomic rollback).
- Silent drift (hourly timer + healthcheck ping tells you which host
  hasn't synced).

**Does not protect against**
- Compromise of the hub (nas) root account. Anyone with root on nas can
  push arbitrary config to any host. Equivalent to today's SSH model.
- Attacker on the WireGuard mesh + leaked token. Keep tokens 0400.
- Supply-chain in the content repo itself. See `docs/hardening.md` for
  signed-manifest next steps.

## Repository layout

```
fleet-sync/
├── server/
│   └── fleet_config_server.py      # HTTP server
├── client/
│   └── fleet-sync.sh               # pull/validate/apply/reload script
├── systemd/
│   ├── fleet-config-server.service # hub daemon unit
│   ├── fleet-sync.service          # client oneshot unit
│   └── fleet-sync.timer            # client timer
├── examples/
│   ├── tokens.json.example         # server: per-host token map
│   ├── client.conf.example         # client: server URL + token path
│   └── alloy.manifest.example      # client: per-service manifest
├── install.sh                      # server|client|both installer
└── README.md                       # this file
```

## Content-repo layout (expected by the client)

A content repo served by this mechanism looks like:

```
fleet-config/
└── alloy/                          # one directory per service
    ├── modules/                    # shared across hosts
    │   └── fleet_*.alloy
    └── hosts/                      # per-host specialisation
        ├── nas/
        │   └── config.alloy
        └── mum-nas/
            └── config.alloy
```

Adding a new service (e.g. `mcp-host-tools/`) is additive — drop a
directory in at the content root, write a manifest on each host that
consumes it.

## Bootstrap (hub)

```
sudo ./install.sh server
# Edit /etc/fleet-sync/tokens.json — add one entry per host
sudo systemctl enable --now fleet-config-server.service
# Open WG-subnet input on the chosen port (iptables / firewall).
```

## Bootstrap (client, including nas as its own first client)

```
sudo ./install.sh client
echo -n "the-bearer-token-for-this-host" | sudo tee /etc/fleet-sync/token
sudo chmod 0400 /etc/fleet-sync/token
sudo $EDITOR /etc/fleet-sync/client.conf
sudo install -m 0644 examples/alloy.manifest.example \
  /etc/fleet-sync/manifest.d/alloy.manifest
# Dry-run once by hand:
sudo /opt/fleet-sync/fleet-sync.sh
# Then enable the timer:
sudo systemctl enable --now fleet-sync.timer
```

## Manifest format

One file per service, under `/etc/fleet-sync/manifest.d/<service>.manifest`.
Lines are either file mappings or control directives.

```
# file mapping: <src-path-on-server>   <dst-path-on-host>
alloy/modules/fleet_levels.alloy   /zfs/Apps/config/alloy/modules/fleet_levels.alloy
alloy/hosts/__HOST__/config.alloy  /zfs/Apps/config/alloy/config.alloy

# control directives: exactly one of each, optional
validate:    <shell command — FLEET_STAGE and FLEET_HOST are exported>
reload:      <shell command — run after atomic apply>
healthcheck: <url to ping after successful reload>
```

`__HOST__` is replaced at sync time with `hostname -s` (or
`HOSTNAME_OVERRIDE` from client.conf).

If reload fails, the client restores the previous file contents from
the local backup and logs the failure. The service stays on old config.

## Adding a second consumer (e.g. mcp-host-tools)

Before onboarding a service whose config controls executable behaviour
(command allowlists, auth rules, etc.), read `docs/hardening.md` and
enable at least signed manifests. Alloy's trust level is "observability
only"; mcp-host-tools is a full tier higher.
