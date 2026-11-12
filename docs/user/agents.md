# Agents

While Dictate runs, it serves dictations and call transcripts over MCP at `http://127.0.0.1:7766/mcp`, on this Mac only. Every request carries the token in `~/Library/Application Support/Dictate/mcp-token`. To add it to Claude Code:

```sh
claude mcp add --transport http --scope user dictate http://127.0.0.1:7766/mcp \
  --header "Authorization: Bearer $(cat ~/Library/Application\ Support/Dictate/mcp-token)"
```

Settings, Agents has Copy MCP setup, which copies the same command and a JSON config with your address and token filled in.

An agent can list and search online calls and dictations, read a transcript, follow a live call with `wait_for_transcript`, tag calls, and start and stop a call recording. `dictate-cli mcp` serves the same thing when the app isn't running. [MCP.md](../MCP.md) has every tool.

The server listens on `127.0.0.1` unless you change the host in Settings, Agents, and answers nothing without the token. The same page turns the server off, changes the port, copies or regenerates the token (agents holding the old one stop working), and switches each tool on or off. Tools that start a recording or change anything (`start_recording`, `stop_recording`, `correct_*`, `add_key_terms`, `remove_key_terms`, `tag_call`, `undo_edit`) start off, because what the other side of a call says is read by your agent and could steer it. A tool that is off is missing from the list agents see and refuses calls.
