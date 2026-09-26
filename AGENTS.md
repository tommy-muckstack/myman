# AGENTS.md

This file is for coding agents (Claude Code, Cursor, Codex, Grok Bot, and others) working in this repository. If you want to *use* My Man as a tool rather than change it, start with the [README agent section](README.md#for-ai-agents-claude-grok-bot-cursor) or [`llms.txt`](llms.txt).

## What lives where

- `src/` is the Swift macOS app (SwiftPM, macOS 14.2+). Agent actions are handled in `src/Core/AgentActions.swift`.
- `integrations/brain/` is the Node companion: the `myman` CLI (`app-cli.mjs`), the read-only Brain MCP server (`server.mjs`), and the app MCP server (`app-server.mjs`). `actions.json` is the one catalog of app actions and their schemas. Bundles in `src/Resources/BrainCompanion/` are generated from it.
- `integrations/linux/` is the Linux companion for agents (X11, Hyprland/Omarchy, Sway). It exposes the same MCP tool names as the Mac.
- `skills/myman-brain/SKILL.md` is the skill agents load. `plugin.json` and `mcp.json` make the repository an Agent Plugin.
- `docs/` has the references. Start with `docs/agent-cli.md` and `docs/agent-cli-parity.md`.

## Checks to run

```bash
# Mac app (needs Xcode / Swift on macOS)
swift build
swift build -c release --arch arm64 --arch x86_64
swift test

# Brain companion and CLI
npm ci --ignore-scripts --prefix integrations/brain
npm test --prefix integrations/brain
npm run bundle --prefix integrations/brain        # after editing companion sources
npm run check-bundle --prefix integrations/brain

# Linux companion
cd integrations/linux && npm ci --ignore-scripts && npm run bundle && npm run check-bundle
xvfb-run -a -s "-screen 0 1280x800x24" npm test
```

CI runs the Swift build and tests on macOS for every pull request, and the Linux suite whenever Linux files change.

## Rules

- One focused change per pull request. Say what changed and how you verified it, with a screenshot or short recording for anything visible.
- **Never weaken permissions.** Agent grants start off and only the person turns them on. Do not add a way for an agent to grant itself access, and do not change existing grant behavior.
- Keep Mac and Linux in step. A new action goes in `actions.json`, gets the same name and schema on both platforms, and returns a structured unsupported error where a platform can't do it yet. Update `docs/agent-cli-parity.md`.
- Commit regenerated bundles together with the source change, or `check-bundle` fails.
- Never commit anyone's Brain export, recordings, screenshots, transcripts, credentials, or private paths. Use synthetic fixtures.
- Follow the house rules in [CONTRIBUTING.md](CONTRIBUTING.md) (design tokens, panel sizing, audio, privacy). FluidAudio stays pinned.
- Agent-surface changes follow the [marketplace release policy](docs/cursor-marketplace-release.md). Releases are maintainer-only.
