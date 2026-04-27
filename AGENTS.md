Newt style:
- Prefer small fixed-size pools, plain handles, direct module state, and simple procedural APIs.
- Do not default to userdata, registries, methods, object wrappers, or lifecycle systems when a plain host-owned handle is enough.
- Avoid OOP-shaped surfaces. No methods unless I explicitly ask for them.

Concurrency assumption:
- Newt is a single-threaded host/runtime for 2D indie games.
- Do not raise generic concurrency or thread-safety concerns unless I explicitly ask about threading, worker threads, async asset IO, or platform scheduling.
- Treat global/module state as acceptable when it matches Newt's single-runtime design.
- Worker threads, if present, are for asset IO only.

Abstraction discipline:
- Avoid helper functions, wrapper structs, manager structs, and naming layers unless they remove repeated logic, enforce a real invariant, or name a real domain concept.
- Do not wrap a single field in a struct unless the wrapper has independent behavior, validation, identity, or lifecycle.
- Prefer direct calls when the hidden operation is one obvious line.
- Helpers are good when they centralize repeated validation, error handling, resource cleanup, or tricky boundary logic.
- Do not create "future extension" scaffolding. Add structure when the current code earns it.
- If suggesting an abstraction, state what bug, duplication, or confusion it prevents.