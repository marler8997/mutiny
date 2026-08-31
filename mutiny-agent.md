# Driving Mutiny

You are being asked to modify a running Unity game using **Mutiny**, a scriptable DLL injector. A player will ask for something like "make me invincible", "infinite stamina", or "no fall damage". Your job is to find the right classes in the game, write a Mutiny script, run it, and report what happened.

**The game is a real program someone is playing. Crashing it loses their progress.** Most of this file is about not doing that. Read "Rules that prevent crashes" before writing any script.

## Running the CLI

**`mutiny` may not be on PATH.** It is always installed here:

```
%LOCALAPPDATA%\mutiny\bin\mutiny.exe          (cmd)
& "$env:LOCALAPPDATA\mutiny\bin\mutiny.exe"   (PowerShell)
```

Try `mutiny` first; if the shell reports it isn't recognised, fall back to the full path rather
than concluding Mutiny isn't installed. Everywhere below, `mutiny` means whichever of the two
works.

## The loop you will follow

1. `mutiny scan` - lists every process with a mono or il2cpp runtime. Find the game's PID.
2. `mutiny inject <PID>` - gets Mutiny into the process. Only needed once per unique PID.
3. `mutiny run-script <PID> @decomp` - prints all information needed to decompile/introspect on the game including the runtime (mono vs il2cpp) and binary files.
   lives on disk.
4. Work out which classes and methods you need (see "Finding the right code").
5. Write a script file, then run it and read the output.

Run `mutiny` with no arguments for the authoritative command list. This file can go out of date; that output cannot.

## Where scripts go

```
%LOCALAPPDATA%\mutiny\app\<Name>\
  log              everything the injected DLL logs, including @Log output from scripts
  mods\<name>      persistent effects, these files are monitored by the injected DLL for changes and are automatically re-executed when changed
  scripts\<name>   unliks mods, only executed when requested via `mutiny <PID> run-script <SCRIPT_NAME>`.
```

`<Name>` is the game's exe name without `.exe`. Mods and scripts have **no extension**.

Which directory to use is decided by *lifetime*, not content - both hold the same language:

- **A question** ("what's the player's health?") goes in `scripts\`. Run it with
  `mutiny run-script <PID> <name>`; its output comes back on stdout.
- **An effect that must persist** ("keep me at full health") goes in `mods\`. It starts running by
  itself as soon as you write the file, and re-runs from the top every time you change the text.

Writing a file into `mods\` starts it immediately.

## Finding the right code

`mutiny run-script <PID> @decomp` gives you tab-separated lines:

```
runtime   mono
exe       C:\...\REPO\REPO.exe
assembly  Assembly-CSharp   C:\...\REPO_Data\Managed\Assembly-CSharp.dll
```

Game-specific code is almost always in **`Assembly-CSharp`**. `UnityEngine.*` assemblies are the
engine itself and are rarely what you want.

There is not yet a tool that lists a class's methods offline, so discovery is currently:
`@LogClass(@ClassOf(someObject))` in a `scripts\` file prints the fields and methods of an
object's class. Use that to check a member exists **before** you write a mod that depends on it.

## The script language

It is not C#, JavaScript, or Python. It is small and strict. Everything below is the whole
language *as it stands today* - if something is not listed here, it does not exist yet.

```
// line comments only

var x = 1                   // declare; the initializer is required
set x = x + 1               // assign to an existing variable or field
                            // `x = 1` is a SYNTAX ERROR, you must write var or set

if (x < 10) { @Log("small") }   // no `else` yet

loop
    if (done()) { break }
    yield 1000              // sleep 1000ms, let other scripts run, then resume here
continue                    // `continue` jumps back to `loop`; it ENDS the loop body

fn name(a, b) { @Log(a) }   // functions
```

**Never write `new`.** It is a reserved keyword that is parsed but *not yet implemented* — the
body is an unfinished `@panic`. It is meant to work eventually, but today it does not give you a
syntax error; it panics Mutiny inside the game process, and the game can then never be closed
normally. Until it lands there is no way to construct an object, so work with objects the game
already has.

Things that will surprise you:

- **`loop` ... `continue` is the loop.** `loop` marks the top, `continue` jumps back to it, and
  `break` exits. The body is not brace-wrapped.
- **A second `loop` in the same block is rejected** with "cannot loop inside loop". Putting one
  inside an `if` block is not caught by that check, but nothing tests it and `break`/`continue`
  across that boundary is unexplored — so write one loop at a time.
- **No `else` yet.** Write a second `if` with the inverted condition.
- **A statement whose value is unused is an error.** If you call a method that returns something
  and you don't want it, wrap it: `@Discard(obj.Method())`.
- **You cannot reach a class straight off an assembly.** Call `@Class` first:

  ```
  var game = @Assembly("Assembly-CSharp")
  var PlayerHealth = @Class(game.PlayerHealth)      // correct
  var bad = game.PlayerHealth.Heal(1)               // WRONG
  ```

### The whole grammar

```
program    := statement*
statement  := "var" ident "=" expr        // declare, initializer required
            | "set" ref "=" expr          // assign; ref may be a.b.c
            | "if" "(" expr ")" block     // no else yet
            | "loop"                      // marks the top of a loop
            | "continue"                  // jumps back to "loop"
            | "break"                     // exits the loop
            | "yield" expr                // expr must be an integer (milliseconds)
            | "fn" ident "(" params ")" block
            | expr                        // ONLY if it produces no value
block      := "{" statement* "}"
ref        := ident ( "." ident )*
expr       := operand ( binop operand )*
operand    := int | string | ref | call | builtin "(" args ")"
call       := ref "(" args ")"
binop      := "+" | "-" | "/"                        // math priority
            | "==" | "!=" | "<" | "<=" | ">" | ">="  // comparison priority, lower
```

Two precedence levels only: math binds tighter than comparison. That operator list is exhaustive
**as of today** — the language is young and still being built out, so these are gaps rather than
deliberate exclusions, and they will likely be filled in over time:

- **No `*` yet.** Division exists, multiplication doesn't. Use repeated addition, or restructure
  to avoid needing it.
- **No `&&` or `||` yet.** Nest `if`s instead.
- **Floats can be read and compared, but not written as literals yet.** Reading a `float`/`double`
  field or return value works, and comparing it against an integer works
  (`if (health < 50)`). You can pass an integer where a `float` or `double` parameter is expected
  — `SetHealth(100)` converts correctly. What you cannot yet write is a fractional literal like
  `1.5`, so a value between integers has to come from the game itself.
- **A conversion that would lose precision is a hard error**, not a silent rounding. Passing an
  integer too large to be represented exactly stops the script with
  "cannot convert N to r4 without losing precision" rather than corrupting the value.
- `+` and `-` overflow is a runtime error, and dividing by zero is a runtime error. Both stop the
  script rather than wrapping silently.

Work within what's here; don't write something that "should" work and hope. If a gap genuinely
blocks the player's request, say so plainly rather than inventing a workaround that corrupts
memory — see the rules below on argument types.

### Builtins and their argument types

| builtin | takes | notes |
|---|---|---|
| `@Assembly(s)` | **string literal** | not a variable — `@Assembly(name)` fails |
| `@TryAssembly(s)` | **string literal** | same; returns nothing instead of erroring if absent |
| `@Class(a.B)` | an **assembly field** | must be written `assembly.ClassName`, nothing else |
| `@ClassOf(o)` | an object | the class of a live object |
| `@LogClass(c)` | a class | prints its fields and methods |
| `@Log(...)` | any number of anything | concatenates them |
| `@ToString(v)` | anything | |
| `@IsNull(v)` / `@NotNull(v)` | anything | return an integer 0 or 1 |
| `@Assert(v)` | an integer | |
| `@Discard(v)` | anything | the only way to throw away a return value |
| `@Exit()` / `@Nothing()` | no arguments | |

`@Log` output goes to the log, and also back to you over the pipe when the script was started
with `run-script`.

## Rules that prevent crashes

These are not style advice. Each one is a way to take the game down.

1. **Methods are resolved by name and argument COUNT only - never by type.** Mutiny does not check
   that your arguments match the parameters. Passing the wrong types is not an error; it is
   silent memory corruption followed by a crash later.

2. **Every integer you pass is sent as a 64-bit integer, whatever the method declares.** A method
   taking `float`, `int`, or `bool` will reinterpret those bits as garbage. `Heal(100)` on a
   `Heal(float)` does *not* heal 100. This is the single most likely way to break something, and
   there is currently no way to pass a real float.

3. **Scripts run on Mutiny's own thread, not Unity's main thread.** Most Unity engine APIs must be
   called from the main thread and will fault elsewhere. Prefer plain field reads/writes and
   game-logic methods; avoid anything that creates GameObjects, touches rendering, loads scenes,
   or calls into `UnityEngine.*`.

4. **Null-check before dereferencing.** A player object may not exist yet at the moment your
   script runs. Use `@IsNull` / `@NotNull` and `yield` in a loop until it appears, as in the
   example below.

5. **Prefer reading before writing.** Read a value and `@Log` it first to confirm you have the
   right object and the units you expect, then write.

6. **Set a value, don't accumulate one.** Read the current value, compute the difference, and
   apply that - a mod re-runs whenever its file changes, and repeated addition compounds.

## Tell the player about these

- **After injecting, the game's close button stops working.** They must quit it from Task Manager.
  This is a known Mutiny bug, not something your script caused. Warn them before you inject.
- **`mutiny run-script` always exits 0**, even when the script failed. Read the output to find out
  whether it worked; do not trust the exit code.
- **A syntax error stops the whole script**, and the message names a line number and what was
  expected. Read it - the messages are specific.

## A worked example

A `mods\` file that waits for the player to exist, then heals them:

```
var game = @Assembly("Assembly-CSharp")
var SemiFunc = @Class(game.SemiFunc)

@Log("waiting for the player...")
loop
    var p = SemiFunc.PlayerAvatarGetFromSteamID("76561197960287930")
    if (@NotNull(p)) { break }
    yield 2000
continue

var player = SemiFunc.PlayerAvatarGetFromSteamID("76561197960287930")
@LogClass(@ClassOf(player.playerHealth))
player.playerHealth.Heal(99999999, 0)
@Log("healed")
```

Note what it does before touching anything: names the assembly, resolves the class explicitly,
waits for the object instead of assuming it exists, and logs the class so the member names are
confirmed rather than guessed.
