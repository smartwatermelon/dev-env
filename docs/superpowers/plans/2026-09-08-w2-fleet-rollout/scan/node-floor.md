# node-floor findings (measured 2026-09-08)

Three repos fail `node-floor` (floor = 22). Matches N1b's corrected live set:
`Gmail-MCP-Server` no longer exists (404 under both orgs), `tensegrity` has
no sub-floor pin (passes node-floor cleanly in this scan).

## `smartwatermelon/gmail-newsletter-filter`

```text
::error::package.json engines.node: >=20.0.0: Node 20 is below the supported floor (22)
::error::1 Node pin(s) below floor 22. Node 20 reached EOL 2026-04-30.
```

## `nightowlstudiollc/kebab-tax`

```text
::error::.nvmrc: 20.19.4: Node 20 is below the supported floor (22)
::error::.github/workflows/ci.yml: node-version: 20: Node 20 is below the supported floor (22)
::error::.github/workflows/ci.yml: node-version: 20: Node 20 is below the supported floor (22)
::error::.github/workflows/deploy-workers.yml: node-version: 20: Node 20 is below the supported floor (22)
::error::.github/workflows/deploy-workers.yml: node-version: 20: Node 20 is below the supported floor (22)
::error::.github/workflows/deploy-workers.yml: node-version: 20: Node 20 is below the supported floor (22)
::error::.github/workflows/publish-changelog.yml: node-version-file .nvmrc -> 20.19.4: Node 20 is below the supported floor (22)
::error::.github/workflows/release-gate.yml: node-version: 20: Node 20 is below the supported floor (22)
::error::8 Node pin(s) below floor 22. Node 20 reached EOL 2026-04-30.
```

8 pins, all via the shared `.nvmrc` (`ci.yml` reads it twice) plus 5 explicit
`node-version: 20` lines. Matches the plan's Task 7 target list exactly:
`.nvmrc`, `ci.yml` x2, `deploy-workers.yml` x3, `publish-changelog.yml` (via
`.nvmrc`), `release-gate.yml`.

## `nightowlstudiollc/reliquarist`

```text
::error::package.json engines.node: >=20.0.0: Node 20 is below the supported floor (22)
::error::.github/workflows/ci.yml: node-version: 20: Node 20 is below the supported floor (22)
::error::2 Node pin(s) below floor 22. Node 20 reached EOL 2026-04-30.
```
