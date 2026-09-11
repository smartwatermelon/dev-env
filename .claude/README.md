# Claude Code Infrastructure - Project-Specific

This directory was automatically created by Git template when you initialized or cloned this repository.

## What is this?

The `.claude/` directory provides project-specific configuration and extensions for Claude Code CLI (CCCLI) collaboration. It integrates with global infrastructure at `~/.claude/` to provide:

- Project-specific configuration (Node version, required tools, deployment secrets)
- Custom git hook extensions for project-specific validation
- Project-local documentation and patterns

## Directory Structure

```
.claude/
├── README.md                  # This file
└── config.sh.template         # Template for project configuration
```

Project-specific hook extensions do **not** live here. They go in
`.project-hooks/` at the repository root — see Option 3 below.

## Quick Start

### Option 1: No Additional Configuration Needed

If your project doesn't need special validation, required secrets, or version constraints, **you're done**! Your project already benefits from global infrastructure:

- Global git hooks (pre-commit, pre-push)
- Code review automation
- Branch protection
- Standard workflows

### Option 2: Add Project Configuration

If you need project-specific settings:

1. Copy the template:

   ```bash
   cp .claude/config.sh.template .claude/config.sh
   ```

2. Edit `.claude/config.sh` to define:
   - Required Node version
   - Required tools (EAS, Maestro, jq, etc.)
   - Deployment secrets
   - Custom pre/post build hooks

3. Update your build/deploy scripts to source the config:

   ```bash
   # In build scripts
   source "${HOME}/.claude/lib/build-commons.sh"
   [[ -f ".claude/config.sh" ]] && source ".claude/config.sh"
   run_preflight_checks

   # In deploy scripts
   source "${HOME}/.claude/lib/deploy-commons.sh"
   source ".claude/config.sh"
   verify_cloudflare_secrets "${DEPLOYMENT_REQUIRED_SECRETS[@]}"
   ```

### Option 3: Add Custom Hook Extensions

If you need project-specific validation:

Extensions live in `.project-hooks/` at the repository root, named for the
git hook they extend. The global hooks run exactly two paths:
`.project-hooks/pre-commit` and `.project-hooks/pre-push`.

1. Create the file, named for its hook:

   ```bash
   mkdir -p .project-hooks
   touch .project-hooks/pre-commit
   chmod +x .project-hooks/pre-commit
   ```

   The executable bit is the activation switch — a non-executable file is
   silently skipped.

2. Write your validation logic:

   ```bash
   #!/usr/bin/env bash
   # Extension contract:
   #   - Exit 0: Check passed (allow git operation)
   #   - Exit 1: Check failed (block git operation)

   # Your validation logic here
   if [[ condition_fails ]]; then
     echo "ERROR: Validation failed"
     exit 1
   fi

   exit 0
   ```

3. The extension then runs on every commit or push, after the global lint
   pass and before the AI review.

## Common Patterns

### Node.js Project with Version Requirement

```bash
# .claude/config.sh
export REQUIRED_NODE_VERSION="20"
```

### Project with Deployment Secrets

```bash
# .claude/config.sh
export DEPLOYMENT_REQUIRED_SECRETS=(
  "API_KEY"
  "DATABASE_URL"
  "JWT_SECRET"
)
```

### Custom Security Check

```bash
# .project-hooks/pre-commit
#!/usr/bin/env bash

# Block commits with hardcoded API keys
if git diff --cached | grep -iE 'API_KEY.*=.*"[A-Za-z0-9]{32}"'; then
  echo "ERROR: Hardcoded API key detected"
  exit 1
fi

exit 0
```

## Integration with Global Infrastructure

Global hooks at `~/.config/git/hooks/` run project extensions from
`.project-hooks/`, not from this directory. They look for exactly two paths —
`.project-hooks/pre-commit` and `.project-hooks/pre-push` — and run each only
if it is executable.

Earlier versions of this file claimed the hooks discovered extensions inside
`.claude/hooks/extensions/`. They never did. That scaffold was inert in every
repo that carried it (smartwatermelon/dev-env#110).

**Global Infrastructure Documentation**: `~/.claude/docs/INFRASTRUCTURE.md`

## Files Included

### config.sh.template

Template for project configuration. Copy to `config.sh` and customize with your project's requirements.

There is deliberately no example extension file here. This directory once
shipped `hooks/extensions/example.sh.disabled`, which nothing ever executed;
it was removed fleet-wide (smartwatermelon/dev-env#110). Write extensions
directly in `.project-hooks/` instead — see Option 3 above.

## Next Steps

1. **Review your needs**: Do you need project-specific configuration or validation?
2. **If yes**: Follow Quick Start Option 2 or 3 above
3. **If no**: You're done! Just start working

## Documentation

- **Global Infrastructure**: `~/.claude/docs/INFRASTRUCTURE.md`
- **Build Patterns**: `~/.claude/docs/BUILD_PATTERNS.md` (if exists)
- **Deployment Patterns**: `~/.claude/docs/DEPLOYMENT_PATTERNS.md` (if exists)
- **Hook System**: `~/.claude/docs/HOOKS.md` (if exists)

## Troubleshooting

### Extensions not running?

```bash
# Check the extension exists and is executable
ls -la .project-hooks/

# Make executable if needed — this is the activation switch, and a
# non-executable extension is skipped silently
chmod +x .project-hooks/pre-commit .project-hooks/pre-push
```

Check the filename too: only `pre-commit` and `pre-push` are run, and only at
the repository root. Any other name is ignored.

### Config not being used?

```bash
# Verify config exists and is sourced
ls -la .claude/config.sh

# Check your build/deploy scripts source it
grep -r "source.*config.sh" scripts/
```

### Need help?

See global infrastructure documentation at `~/.claude/docs/INFRASTRUCTURE.md` for complete reference.
