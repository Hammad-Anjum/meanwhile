# Meanwhile

A macOS notch app that asks you short questions while your coding agent (Claude Code, Codex, Cursor) works: about your codebase, about what the agent found, and from decks you choose.

Status: early build. See [docs/](docs/README.md) for the design and [docs/mvp-plan.md](docs/mvp-plan.md) for the task list. A clickable mockup is in [mockup/index.html](mockup/index.html). Progress, with diagrams of the current structure, is in [docs/progress.html](docs/progress.html).

## Build

Requires macOS 14+ and a Swift 6 toolchain (Xcode 16+ or the Command Line Tools). Everything builds with SwiftPM.

```sh
make build    # swift build: the meanwhile and meanwhile-hook binaries
make test     # core library tests (swift test)
make run      # build and run `meanwhile run` in the foreground; look for the icon in the menu bar
```

Or directly: `swift run meanwhile run`. `meanwhile --help` lists the commands.

## Layout

| Path | What |
|---|---|
| `Sources/MeanwhileIPC` | Paths and wire format shared by the app and the hook |
| `Sources/MeanwhileCore` | The engine: events, sessions, storage, questions, scheduling |
| `Sources/MeanwhileHook` | `meanwhile-hook`, the small program agents call from their hooks |
| `Sources/MeanwhileApp` | The `meanwhile` command: the background notch process and the CLI |
| `Tests/` | Core tests and recorded hook payloads |
| `docs/` | Design docs |
