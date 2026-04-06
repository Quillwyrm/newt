The policy I’d recommend for Luagame is:

Programmer misuse: hard Lua error.
Expected runtime failure from the OS/driver/file system/resource creation: return nil, err or false, err.
Ephemeral runtime state failures during control operations: no-op or falsey return, but only where that behavior is intentional and documented.
Boot-critical failures: fail loudly and specifically, not by printing and falling through to a later generic message.

Yeah. Your intuition is basically right.

Once Lua exists and the user is inside the Luagame API, the default should be:

push errors to Lua.

Use plain Odin-side stderr / early returns only for host boot phases that happen before Lua exists, or for unrecoverable engine-fatal shutdown cases where there is no sane Lua call boundary to report through.

That is the cleanest split.

More concretely:

Before `Lua = lua.L_newstate()` succeeds: Odin/host errors only.
During bootstrap code that runs outside a Lua-call boundary: Odin/host errors only, unless you explicitly wrap that phase in protected Lua execution and surface it there.
Inside any `lua_*` API proc: Lua errors or Lua return-values, never silent host printing.
Inside `runtime.init/update/draw` callbacks: Lua errors, via your protected call path, not Odin panics or stray stderr if you can avoid it.

That part is worth locking in as a rule.

Now the actual punch list.

Your source does not have one universal error model yet. It has four:

hard Lua error
`nil, err` or `false, err`
silent no-op
host stderr + return

That is the thing to unify.

My recommended target policy for Luagame would be:

1. Caller contract violation, bad arity, bad type, invalid enum token, structurally impossible call:
   hard Lua error.

2. Expected external/runtime failure from OS, disk, driver, asset loading, backend creation:
   return `nil, err` or `false, err`.

3. Commands against ephemeral runtime state that may legitimately have gone away:
   silent no-op or falsey query result, but only for handle/resource liveness cases where you explicitly want “best effort”.

4. Engine boot failure before Lua is active:
   host stderr and abort.

5. Engine boot failure after Lua is active and happening because Lua requested something:
   prefer Lua error, not stderr.

That would fit Luagame well.

Now module by module.

Window

This is your weakest module from an error-policy standpoint.

Problems:

`window.init` mixes Lua contract checking with host stderr backend failures.
If `CreateWindow` fails, it prints and returns `0`.
If `CreateRenderer` fails, it prints and returns `0`.
Then the main engine later prints `runtime.init() did not call window.init(...)`.

That means the true failure is decoupled from the Lua callsite and gets blurred into a generic structural complaint.

That is the biggest concrete issue in the whole codebase.

What I’d change:

Inside `lua_window_init`, backend creation failures should be `lua.L_error`, with the SDL error string embedded.

Not:
“window failed” to stderr, then limp onward.

But:
`window.init: CreateWindow failed: ...`
`window.init: CreateRenderer failed: ...`

That gives the failure to Lua at the exact place the user called it.

Second issue:
`SetRenderVSync` failure currently just prints and continues.

This one is more nuanced. I would not make that fatal unless you truly require vsync. For an indie framework, continuing is fine. But do not just print and move on silently from the Lua user’s perspective.

Two valid options:

Option A:
Keep it non-fatal and expose a warning system later.

Option B:
For now, make it a Lua error if your engine contract is “vsync is mandatory right now”.

I would lean A, but it should be intentional.

Third issue:
The older getters use `check_window_safety`, which is good, but the init path itself is not using the same philosophy. So the module feels split between “strict” and “legacy print-and-return”.

My verdict:
Window needs one cleanup pass before beta.

Input

Input is mostly fine. Honestly one of the cleaner modules.

Good:
unknown key tokens error loudly
bad usage errors loudly
uninitialized-state guards exist
queries are deterministic and simple

I would not add a big `check_system_safety` pattern here unless the API actually depends on a booted subsystem from Lua’s perspective.

Input is different from graphics/window/audio because the engine initializes it internally before runtime update flow. Users do not “construct” input. So there is less need for a public-facing system guard helper everywhere.

What I would keep:
input should error on invalid token/domain misuse.
input should not silently eat nonsense names.

No major cleanup needed here unless there are a few old monotome-style message strings you want to normalize.

Filesystem

Filesystem is closest to the policy I’d want everywhere.

Good:
bad arity and bad caller shape errors loudly
OS failures come back as `nil, err` or `false, err`
there is almost no ambiguity

This module is already the model.

The only thing I’d do is make sure every function in the docs states the contract in exactly that form. But source-wise, this is the one I’d treat as reference style.

Graphics

Graphics is mostly good structurally, but it has a lot of silent returns. Some are correct. Some should probably be louder.

The good parts:

`check_render_safety` is the right pattern.
Resource creation/loading returning `nil, err` is right.
Misuse like invalid blend/filter mode or setting a non-canvas as canvas throws, which is right.

The mixed parts:

Many draw operations and pixelmap ops do this pattern:
checked userdata, then if underlying backend pointer is nil, just `return 0`.

That means a dead/freed image or pixelmap often silently evaporates.

This is defensible if manual `free(...)` is part of the API and you want post-free use to behave like a dead handle. But you need to decide that explicitly.

Right now the module treats dead resources more softly than it treats bad call shape. That is okay, but only if consistent.

Here is my take:

For draw commands on dead resources:
silent no-op is acceptable.

For state mutation commands on dead resources:
also acceptable, if you want post-free safety over noisiness.

For data queries on dead resources:
better to return falsey/nil than silently nothing, because queries are usually where users debug assumptions.

For structurally impossible operations, like `set_canvas(non_canvas_image)`:
hard Lua error, which you already do.

Concrete graphics mismatches I’d clean:

`graphics.draw_image`, `draw_image_region`, `set_canvas`, update-image functions, and many pixelmap ops all use slightly different “invalid/dead userdata” behavior. Unify that.

Pick one of these two models:

Model 1:
Dead resource use is a no-op everywhere for mutators/draws, nil/false for queries.

Model 2:
Dead resource use is always a Lua error: “resource has been freed”.

For Luagame I’d lean Model 1, because you already have manual `free()` and C-backed userdata. Soft-death semantics are reasonable.

But then document it, and make it consistent.

Also:
`graphics.debug_text` printing SDL failure to stderr instead of surfacing it is the same smell as window init, just less severe. If the operation fails due to backend error, that should ideally become a Lua error or at least a deterministic falsey result. Raw stderr from inside a Lua API proc is the wrong layer.

Audio

This is the module that needs the most cleanup.

The architecture is good. The error semantics are not unified.

The main problems:

1. Bus index failures silently return in many functions.

`set_bus_volume`, `fade_bus`, `set_bus_pitch`, `set_bus_pan`, `set_bus_lpf`, `set_bus_hpf`, `set_bus_delay_feedback`, `set_bus_delay_mix`, `pause_bus`, `resume_bus`, `stop_bus` all do variations of “if bad index return 0”.

That is not a dead-handle case. That is caller misuse.
It should be a Lua error.

Wrong bus id is not like a voice expiring underneath you.
It is an invalid API argument.
That should be loud.

2. Playback failure returns handle `0` with no reason.

`audio.play` and `audio.play_at` can fail from:
bad bus index
voice allocation failure
stream init failure
backend node creation failure

and they currently collapse to “return 0”.

That is weak.

For Luagame, I would strongly recommend:

`audio.play(...) -> handle | nil, err`
`audio.play_at(...) -> handle | nil, err`

That is the cleanest model.

Because this is not a control operation on a live handle.
It is a creation/request operation that can fail for external reasons.

Returning `0` is C-ish, but not Luagame-ish.

If you really want to keep integer-only handle style, then at minimum:
document `0` as invalid, and add `audio.get_last_error()` or similar.
But that’s worse than just returning `nil, err`.

3. Stream sounds and static sounds fail at different phases.

Static sound load failure is caught in `load_sound`.
Stream sound load can fail later in `play`.

That semantic mismatch is okay internally, but the API must compensate.

That is another reason `play` should be able to return `nil, err`.

Otherwise streamed assets are materially harder to debug than static ones.

4. Dead voice handle semantics are actually mostly okay.

`set_voice_*`, `pause_voice`, `resume_voice`, `stop_voice`, `seek_voice`, `fade_voice`, spatial setters all silently no-op if the handle is dead.

This part I would mostly keep.

Because voice handles are ephemeral runtime objects.
A dead handle is not necessarily programmer misuse. It can happen naturally by timing or by explicit stop.
For an indie framework, “best effort if alive, no-op if dead” is a valid design.

But then lock that as policy:
voice control on dead handle is soft.
voice creation and bus domain misuse are loud.

5. Query behavior is not uniform.

`is_voice_playing(dead)` returns false. Good.
`get_voice_info(dead)` returns nothing. That is weaker.

I would prefer:
`get_voice_info(dead)` returns `nil, nil` or `nil, "dead voice handle"`.

Returning zero values is too slippery in Lua. It invites weird bugs and unpack behavior.

6. A few domain errors are loud and a few are soft.

Invalid pan mode and falloff mode error loudly. Good.
Invalid bus ids silently return. Bad.
That split is not principled right now.

My audio cleanup target would be:

Bad bus id: Lua error.
Bad enum/mode token: Lua error.
Dead voice handle on mutator/control op: no-op.
Dead voice handle on query: falsey/nil result, consistent per function.
Creation/playback/load failure: `nil, err`.
DSP parameter clamping: keep clamping, do not error.

That would make audio feel coherent immediately.

About `check_system_safety`

The pattern is good, but only where there is a real subsystem invariant users can violate.

So:

Window:
yes, keep it.

Graphics:
yes, keep it.

Audio:
yes, add it.

Filesystem:
probably no dedicated system-safety helper needed.
Filesystem does not depend on a created host object in the same way.
It is basically an OS bridge.

Input:
probably no dedicated helper needed unless there are Lua-callable funcs that can truly run before input init in normal usage.
Given your engine boot order, input is mostly internal-global service, not user-constructed subsystem state.

The important thing is not “every module gets a check helper”.
It is “every module with a host object dependency gets one”.

So I’d add something like:

`check_audio_safety(L, "audio.play")`

if audio engine/group graph must be alive.

That lets you avoid weird behavior if audio init ever fails or you later allow no-audio modes.

I would also consider two helper classes, mentally:

`check_*_safety`
for subsystem boot/state validity

`validate_*_domain`
for things like bus index, voice handle class, canvas/resource liveness, etc

That is more scalable than one giant safety concept.

Now the direct answer to your “Lua always?” question.

My answer:

Yes, almost always.

Inside any Lua-exposed API function, prefer:
Lua error for programmer misuse
Lua return values for expected runtime failure

Do not print to stderr from there unless it is purely a mirrored debug log.

Use Odin-side errors only when:
Lua VM is not up yet
you are outside any Lua call boundary
the engine is in teardown or fatal host boot failure territory

That is the clean line.

If you want one rule to pin above your desk, I’d make it:

“If Lua asked for it, Lua should receive the failure.”

That is the right instinct.

My condensed pre-beta cleanup list would be:

1. Fix `window.init` to raise real Lua errors on SDL creation failures.
2. Remove silent bad-bus rejects in audio. Make them Lua errors.
3. Make `audio.play/play_at` return `nil, err` on creation failure instead of `0`.
4. Normalize dead-handle semantics in audio:
   mutators no-op, queries return falsey/nil consistently.
5. Normalize dead-resource semantics in graphics:
   soft no-op for mutators/draws is fine, but do it consistently and document it.
6. Remove stderr printing from Lua API paths where the user should get structured failure instead.
7. Add `check_audio_safety`.
8. Use filesystem as the template for expected runtime failure shape.

That would pull the whole source into one clear philosophy fast.

Would you like me to turn this into a concrete “error handling spec” for Luagame, like 10-15 rules you can apply across every module while refactoring?
