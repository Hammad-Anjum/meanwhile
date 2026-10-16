# Meanwhile

A macOS notch app that asks you short questions while your coding agent (Claude Code, Codex, Cursor) works: about your codebase, about what the agent found, and from decks you choose.

Status: early build. See [docs/](docs/README.md) for the design and [docs/mvp-plan.md](docs/mvp-plan.md) for the task list. A clickable mockup is in [mockup/index.html](mockup/index.html).

## Build

Requires macOS 14+, Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make test     # core library tests (swift test)
make build    # generate App/Meanwhile.xcodeproj and build the app
make run      # build and launch; look for the icon in the menu bar
```

To work in Xcode: `make project && open App/Meanwhile.xcodeproj`.

## Layout

| Path | What |
|---|---|
| `Sources/MeanwhileIPC` | Paths and wire format shared by the app and the hook |
| `Sources/MeanwhileCore` | The engine: events, sessions, storage, questions, scheduling |
| `Sources/MeanwhileHook` | `meanwhile-hook`, the small program agents call from their hooks |
| `App/` | The SwiftUI menu bar app (project generated from `project.yml`) |
| `Tests/` | Core tests and recorded hook payloads |
| `docs/` | Design docs |
