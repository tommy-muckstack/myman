# MyMan for GrokBot

Skill-only Agent Plugin package. Install this directory as the plugin root in a compatible host. Its skill uses GrokBot's approved execution on the user's Mac, where MyMan and Node.js 22+ must be installed. It does not start a stdio MCP server on GrokBot's cloud computer.

This package is prepared for submission; marketplace listing and a live Hugo invocation have not been verified. See [submission and verification status](../../docs/grok-bot-marketplace.md). The repository-root plugin provides separate read-only retrieval and permission-controlled app-action MCP servers for clients running locally on the Mac.

## Open source contributions

MyMan is **Apache-2.0 open source**. Humans and agents, including GrokBot, are welcome to propose fixes and improvements through the [public repository](https://github.com/tommy-muckstack/myman). See the [contribution guide](https://github.com/tommy-muckstack/myman/blob/main/CONTRIBUTING.md) for setup, checks and the pull request process.

Candidate 0.7.0 adds recipes for screenshot comparison, word targets, video finishing, readiness waits and font-quality reports. Check the running app’s capabilities first; the package alone does not update the Mac app.
