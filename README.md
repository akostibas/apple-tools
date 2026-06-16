# apple-tools

Local macOS/Apple integrations as a single CLI, plus a Claude Code skill that
drives it. Read and write Calendar, Reminders, Notes, Contacts, Mail, Messages
(iMessage/SMS), Photos, files, the clipboard, screenshots, and open URIs — all
on the machine it runs on, with no server.

Derived from an internal macOS probe: the same tool implementations, with the
server/networking layer removed and the file handling pointed at the local disk.

## Quick start

```bash
make install               # build the release binary, link it onto PATH, install the skill
apple-tools permissions    # grant macOS access (Calendar, Contacts, Photos, Full Disk Access, …)
apple-tools list           # see the tools
apple-tools calendar list --start 2026-06-15T00:00:00Z --end 2026-06-16T00:00:00Z
```

## CLI shape

```
apple-tools <tool> <action> [--flag value ...]
apple-tools <tool> --json '{"action":"...", ...}'   # raw params
apple-tools <tool> --help                            # parameters for a tool
apple-tools permissions                              # preflight all tools (trigger TCC dialogs)
```

The CLI is **schema-driven**: every tool publishes a `ToolDefinition` (a JSON
schema), and the driver maps `action` → subcommand and each property → a
`--flag`, coercing values to the declared type. There is no per-tool argument
parsing — adding a tool to the library adds it to the CLI automatically.

## Files

File-producing actions (`photos fetch`, `screenshot`, `files fetch`, clipboard
images, attachment fetches) write to a local output dir and return the absolute
`path` in their JSON. Control the location with `--output-dir` or
`$APPLE_TOOLS_OUTPUT_DIR` (default: a private per-user temp dir, `0700`).

## Architecture

```
Sources/
  AppleToolsObjC/   # ObjC shim (safe NSUnarchiver for iMessage attributedBody)
  AppleToolsLib/    # tools, integrations, FileSink seam, CLI arg mapper
  apple-tools/      # the CLI executable (thin; delegates to the lib)
Tests/AppleToolsTests/
skills/apple-tools/  # the Claude skill (SKILL.md)
```

The one seam that decouples the tools from any backend is **`FileSink`**
(`Sources/AppleToolsLib/FileSink.swift`): tools that produce a file call
`fileSink.deliver(filename:data:)` and get back an opaque reference. This CLI
injects `LocalFileSink` (writes to disk, returns a path); a server-backed host
could inject an uploader that returns a file-id instead. This is what makes
`AppleToolsLib` publishable as a shared package reusable by a server-backed
host as well as this CLI.

## Develop

```bash
make build      # release build
make test       # unit tests (live Notes tests gated behind APPLE_TOOLS_NOTES_LIVE=1)
```
