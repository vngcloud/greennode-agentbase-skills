# Plugin Marketplace Refactor Design

**Date:** 2026-06-25
**Status:** Approved

## Goal

Refactor `greennode-agentbase-skills` from a manual `cp -r` install model into a proper marketplace plugin installable with a single command on Claude Code, Codex CLI, and Cursor.

## Problem

Current install flow requires:
1. `git clone`
2. Manual `cp -r .claude/skills/* ~/.claude/skills/`
3. Different target directory per tool

No versioning, no updates, no discovery.

## Approach

**One plugin, self-hosted marketplace.** The GitHub repo itself acts as both the marketplace catalog and the plugin. Users add the marketplace once, then install the plugin — all skills are bundled in a single install.

Supports: Claude Code (primary), Codex CLI, Cursor.
Not supported: Windsurf, GitHub Copilot (no shell-script plugin system).

## Directory Structure

```
greennode-agentbase-skills/
├── .claude-plugin/
│   ├── plugin.json          # Claude Code plugin manifest
│   └── marketplace.json     # Marketplace catalog (repo = marketplace)
├── .codex-plugin/
│   └── plugin.json          # Codex CLI plugin manifest
├── .cursor-plugin/
│   └── plugin.json          # Cursor plugin manifest
├── skills/                  # Moved from .claude/skills/ — content unchanged
│   ├── agentbase/
│   ├── agentbase-wizard/
│   ├── agentbase-deploy/
│   ├── agentbase-identity/
│   ├── agentbase-llm/
│   ├── agentbase-memory/
│   ├── agentbase-monitor/
│   ├── agentbase-gateway/
│   ├── agentbase-policy/
│   └── agentbase-teardown/
└── README.md                # Updated install instructions
```

## File Contents

### `.claude-plugin/plugin.json`

```json
{
  "name": "greennode-agentbase",
  "version": "1.0.0",
  "description": "Full GreenNode AgentBase lifecycle: scaffold → configure → deploy → monitor → teardown. 10 skills including /agentbase-wizard, /agentbase-deploy, /agentbase-monitor.",
  "author": {
    "name": "GreenNode",
    "url": "https://greennode.ai"
  },
  "homepage": "https://github.com/vngcloud/greennode-agentbase-skills",
  "repository": "https://github.com/vngcloud/greennode-agentbase-skills",
  "license": "MIT",
  "keywords": ["agentbase", "greennode", "agent", "deploy", "vngcloud"],
  "skills": "./skills/"
}
```

### `.claude-plugin/marketplace.json`

```json
{
  "$schema": "https://code.claude.com/schemas/marketplace-v1.schema.json",
  "name": "greennode-agentbase",
  "description": "GreenNode AgentBase plugin marketplace",
  "owner": { "name": "GreenNode" },
  "plugins": [
    {
      "name": "greennode-agentbase",
      "source": "./",
      "description": "Full GreenNode AgentBase lifecycle skills",
      "version": "1.0.0",
      "keywords": ["agentbase", "greennode", "agent", "deploy"],
      "category": "deployment"
    }
  ]
}
```

### `.codex-plugin/plugin.json`

Same core fields as `.claude-plugin/plugin.json`, with additional `interface` block:

```json
{
  "name": "greennode-agentbase",
  "version": "1.0.0",
  "description": "Full GreenNode AgentBase lifecycle: scaffold → configure → deploy → monitor → teardown.",
  "author": { "name": "GreenNode", "url": "https://greennode.ai" },
  "homepage": "https://github.com/vngcloud/greennode-agentbase-skills",
  "repository": "https://github.com/vngcloud/greennode-agentbase-skills",
  "license": "MIT",
  "keywords": ["agentbase", "greennode", "agent", "deploy", "vngcloud"],
  "skills": "./skills/",
  "interface": {
    "displayName": "GreenNode AgentBase",
    "shortDescription": "Full AgentBase lifecycle: scaffold, deploy, monitor",
    "developerName": "GreenNode",
    "category": "Deployment"
  }
}
```

### `.cursor-plugin/plugin.json`

Same as `.claude-plugin/plugin.json` (Cursor uses same core format, no `interface` block needed).

## Install Flow After Refactor

### Claude Code
```bash
claude plugin marketplace add github:vngcloud/greennode-agentbase-skills
/plugin install greennode-agentbase
```

### Team distribution (add to project `.claude/settings.json`)
```json
{
  "extraKnownMarketplaces": {
    "greennode-agentbase": {
      "source": { "source": "github", "repo": "vngcloud/greennode-agentbase-skills" }
    }
  }
}
```

### Codex CLI
Add to `~/.codex/config.toml`:
```toml
[plugins]
greennode-agentbase = { source = "github:vngcloud/greennode-agentbase-skills" }
```

### Cursor
Team marketplace → import repo: `vngcloud/greennode-agentbase-skills`

### Manual fallback (any tool)
```bash
cp -r skills/ <your-tool-skills-dir>/
```

## Changes Summary

| Item | Change |
|---|---|
| `skills/` | Created — content moved from `.claude/skills/` unchanged |
| `.claude/skills/` | Deleted |
| `.claude-plugin/plugin.json` | New |
| `.claude-plugin/marketplace.json` | New |
| `.codex-plugin/plugin.json` | New |
| `.cursor-plugin/plugin.json` | New |
| `README.md` | Install section rewritten; Skills Index/Lifecycle Map/Troubleshooting unchanged |

**SKILL.md files are not modified.**

## What Is Not Changed

- All 10 `SKILL.md` files and their content
- `references/` directories
- `scripts/` directories
- `assets/` directories
- Skills Index, Lifecycle Map, Troubleshooting in README

## Versioning

`plugin.json` `version` field must be bumped on every release for users to receive updates via the marketplace. If omitted, every git commit counts as a new version.
