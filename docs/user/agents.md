# Agents

While Voice runs, it serves dictations and call transcripts over MCP at `http://127.0.0.1:7766/mcp`, on this Mac only. Every request carries the token in `~/Library/Application Support/Voice/mcp-token`. To add it to Claude Code:

```sh
claude mcp add --transport http --scope user voice http://127.0.0.1:7766/mcp \
  --header "Authorization: Bearer $(cat ~/Library/Application\ Support/Voice/mcp-token)"
```

An agent can list and search online calls and dictations, read a transcript, follow a live call with `wait_for_transcript`, tag calls, and start and stop a call recording. `voice-cli mcp` serves the same thing when the app isn't running. [MCP.md](../MCP.md) has every tool.

The server listens on `127.0.0.1` only and answers nothing without the token. Settings, General, Agents can read transcripts turns it off and has a button that copies the token.
