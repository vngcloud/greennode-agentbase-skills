# Plugin Marketplace Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `greennode-agentbase-skills` into a proper Claude Code / Codex / Cursor marketplace plugin installable with a single command.

**Architecture:** Move all skills from `.claude/skills/` to `skills/` at the repo root (the standard plugin path), then add three manifest folders (`.claude-plugin/`, `.codex-plugin/`, `.cursor-plugin/`) with `plugin.json` files, plus a `marketplace.json` so the GitHub repo itself acts as a self-hosted marketplace. SKILL.md files and their content are not modified.

**Tech Stack:** Markdown, JSON, Bash (for validation). No build step.

## Global Constraints

- All 10 `SKILL.md` files must be preserved byte-for-byte — content is not changed.
- Plugin name: `greennode-agentbase` (used in `plugin.json` and `marketplace.json`).
- `plugin.json` version: `1.0.0`.
- Schema reference: `https://code.claude.com/schemas/marketplace-v1.schema.json`.
- Validate with: `claude plugin validate .` before committing.

---

### Task 1: Move skills to `skills/` at repo root

**Files:**
- Create: `skills/` (by moving `.claude/skills/` content)
- Delete: `.claude/skills/`

**Interfaces:**
- Produces: `skills/<skill-name>/SKILL.md` for all 10 skills (consumed by Tasks 2–4 via `"skills": "./skills/"` in manifests)

- [ ] **Step 1: Verify current skill list**

```bash
ls .claude/skills/
```

Expected output (10 directories):
```
agentbase          agentbase-deploy   agentbase-gateway  agentbase-identity
agentbase-llm      agentbase-memory   agentbase-monitor  agentbase-policy
agentbase-teardown agentbase-wizard
```

- [ ] **Step 2: Move skills to root**

```bash
mv .claude/skills ./skills
```

- [ ] **Step 3: Verify all 10 skills moved correctly**

```bash
ls skills/
```

Expected: same 10 directories as Step 1.

```bash
# Verify no SKILL.md files are missing
find skills -name "SKILL.md" | wc -l
```

Expected: `10`

- [ ] **Step 4: Remove now-empty `.claude` directory**

```bash
rmdir .claude
```

If `.claude` contains other files (e.g. a `settings.json`), delete only the skills subdirectory and leave the rest:

```bash
# Only if rmdir fails:
ls .claude/
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: move skills from .claude/skills/ to skills/ at repo root"
```

---

### Task 2: Add Claude Code manifest files

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`

**Interfaces:**
- Consumes: `skills/` directory (Task 1)
- Produces: Claude Code plugin + marketplace manifest (consumed by validation in Task 5)

- [ ] **Step 1: Create `.claude-plugin/` directory**

```bash
mkdir .claude-plugin
```

- [ ] **Step 2: Create `.claude-plugin/plugin.json`**

Write the following content exactly:

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

- [ ] **Step 3: Verify `plugin.json` is valid JSON**

```bash
python3 -m json.tool .claude-plugin/plugin.json > /dev/null && echo "valid"
```

Expected: `valid`

- [ ] **Step 4: Create `.claude-plugin/marketplace.json`**

Write the following content exactly:

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
      "description": "Full GreenNode AgentBase lifecycle skills: scaffold, configure, deploy, monitor, teardown.",
      "version": "1.0.0",
      "keywords": ["agentbase", "greennode", "agent", "deploy", "vngcloud"],
      "category": "deployment"
    }
  ]
}
```

- [ ] **Step 5: Verify `marketplace.json` is valid JSON**

```bash
python3 -m json.tool .claude-plugin/marketplace.json > /dev/null && echo "valid"
```

Expected: `valid`

- [ ] **Step 6: Commit**

```bash
git add .claude-plugin/
git commit -m "feat: add Claude Code plugin and marketplace manifests"
```

---

### Task 3: Add Codex CLI manifest

**Files:**
- Create: `.codex-plugin/plugin.json`

**Interfaces:**
- Consumes: `skills/` directory (Task 1)
- Produces: Codex-compatible plugin manifest

- [ ] **Step 1: Create `.codex-plugin/` directory**

```bash
mkdir .codex-plugin
```

- [ ] **Step 2: Create `.codex-plugin/plugin.json`**

Write the following content exactly:

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
  "skills": "./skills/",
  "interface": {
    "displayName": "GreenNode AgentBase",
    "shortDescription": "Full AgentBase lifecycle: scaffold, deploy, monitor",
    "developerName": "GreenNode",
    "category": "Deployment"
  }
}
```

- [ ] **Step 3: Verify valid JSON**

```bash
python3 -m json.tool .codex-plugin/plugin.json > /dev/null && echo "valid"
```

Expected: `valid`

- [ ] **Step 4: Commit**

```bash
git add .codex-plugin/
git commit -m "feat: add Codex CLI plugin manifest"
```

---

### Task 4: Add Cursor manifest

**Files:**
- Create: `.cursor-plugin/plugin.json`

**Interfaces:**
- Consumes: `skills/` directory (Task 1)
- Produces: Cursor-compatible plugin manifest

- [ ] **Step 1: Create `.cursor-plugin/` directory**

```bash
mkdir .cursor-plugin
```

- [ ] **Step 2: Create `.cursor-plugin/plugin.json`**

Write the following content exactly:

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

- [ ] **Step 3: Verify valid JSON**

```bash
python3 -m json.tool .cursor-plugin/plugin.json > /dev/null && echo "valid"
```

Expected: `valid`

- [ ] **Step 4: Commit**

```bash
git add .cursor-plugin/
git commit -m "feat: add Cursor plugin manifest"
```

---

### Task 5: Validate plugin structure

**Files:**
- No new files — validation only

**Interfaces:**
- Consumes: all outputs from Tasks 1–4

- [ ] **Step 1: Run Claude Code plugin validator**

```bash
claude plugin validate .
```

Expected: no errors. If errors appear, fix the reported file before continuing.

Common fixes:
- `skills path not found` → verify `"skills": "./skills/"` and that `skills/` exists at repo root
- `invalid JSON` → run `python3 -m json.tool <file>` to find the syntax error
- `missing required field` → add the missing field (`name`, `version`, or `description`) to the relevant `plugin.json`

- [ ] **Step 2: Verify skills are discovered**

```bash
# Count SKILL.md files — should still be 10
find skills -name "SKILL.md" | sort
```

Expected: 10 paths, one per skill.

- [ ] **Step 3: Dry-run install to confirm marketplace resolves**

```bash
claude plugin marketplace add . --dry-run 2>&1 || echo "dry-run flag not supported, skip"
```

If `--dry-run` is not supported, skip this step — the validate command in Step 1 is sufficient.

---

### Task 6: Update README

**Files:**
- Modify: `README.md` (install section only — Skills Index, Lifecycle Map, Troubleshooting, Repo Layout are unchanged)

**Interfaces:**
- Consumes: install commands confirmed in Tasks 2–4

- [ ] **Step 1: Replace the TL;DR and Install Per Tool sections**

Find the block from `## TL;DR — Install in 30 Seconds` through the end of `### 4. Other SKILL.md-compatible Clients` (inclusive of the compatibility matrix table and the note below it).

Replace it with:

```markdown
## Install in 30 Seconds

### Claude Code

```bash
claude plugin marketplace add github:vngcloud/greennode-agentbase-skills
```

Then inside Claude Code:

```
/plugin install greennode-agentbase
```

**Team distribution** — add to your project's `.claude/settings.json` so teammates are prompted to install automatically:

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
git clone https://github.com/vngcloud/greennode-agentbase-skills.git
cp -r greennode-agentbase-skills/skills/* <your-tool-skills-dir>/
```

### Compatibility

| Tool | Install method | Shell scripts supported |
|---|---|---|
| Claude Code | `/plugin install` via marketplace | Yes |
| Codex CLI | `config.toml` plugin entry | Yes |
| Cursor | Team marketplace UI | Yes |
| Windsurf | Manual copy of `skills/*/SKILL.md` | No (markdown only) |
| GitHub Copilot | Not supported | No |
```

- [ ] **Step 2: Update the Repo Layout section**

Find the `## Repo Layout` section and replace the directory tree:

```markdown
## Repo Layout

```
greennode-agentbase-skills/
├── .claude-plugin/             # Claude Code plugin + marketplace manifests
├── .codex-plugin/              # Codex CLI plugin manifest
├── .cursor-plugin/             # Cursor plugin manifest
├── skills/                     # <-- the skills you install
│   ├── agentbase/              # platform reference
│   ├── agentbase-wizard/       # guided full-lifecycle wizard
│   ├── agentbase-deploy/       # build, push, deploy + Container Registry + OpenClaw
│   ├── agentbase-identity/     # agent identities & outbound auth
│   ├── agentbase-llm/          # platform LLM API keys & models
│   ├── agentbase-memory/       # conversation + semantic memory
│   ├── agentbase-monitor/      # logs, metrics, dashboard
│   ├── agentbase-gateway/      # Resource Gateway (MCP)
│   ├── agentbase-policy/       # authorization policies
│   └── agentbase-teardown/     # delete all resources
└── README.md
```

Each skill folder contains a `SKILL.md` (the contract read by the AI tool) and any helper `scripts/` or `references/` it needs.
```

- [ ] **Step 3: Verify the README renders correctly (spot check)**

```bash
# Check for broken section headers
grep "^##" README.md
```

Expected sections (in order): `## Install in 30 Seconds`, `## Prerequisites`, `## Skills Index`, `## Lifecycle Map` (or inside Skills Index), `## End-to-End Example`, `## Troubleshooting`, `## Repo Layout`, `## Contributing & Extending`, `## Important Notes`

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: update README with marketplace install instructions"
```

---

## Self-Review

**Spec coverage:**
- [x] Move skills from `.claude/skills/` to `skills/` — Task 1
- [x] Add `.claude-plugin/plugin.json` + `marketplace.json` — Task 2
- [x] Add `.codex-plugin/plugin.json` — Task 3
- [x] Add `.cursor-plugin/plugin.json` — Task 4
- [x] Validate — Task 5
- [x] Update README install section — Task 6

**Placeholder scan:** No TBD/TODO found.

**Type consistency:** No code types — JSON fields are consistent across all tasks (`name`, `version`, `description`, `skills`, `author`, `keywords`).
