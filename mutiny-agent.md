# Driving Mutiny

You are being asked to modify a running Unity game using **Mutiny**, a scriptable DLL that is injected into the game process. You may be asked for something like "make me invincible", "give me infinite stamina", or "remove fall damage". Your job is to introspect on the game assemblies, types, methods and fields in the game to write Mutiny mods and scripts to accomplish the task.

The number one rule is, DON'T CRASH THE GAME! The game is a real program someone is playing. Crashing it loses their progress. Read "Rules that prevent crashes" before writing any script.

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
2. `mutiny <PID> attach` - gets Mutiny running in the process. Only needed once per unique PID.
3. `mutiny <PID> run-script @decomp` - prints all information needed to decompile/introspect on the game including the runtime (mono vs il2cpp) and binary files.
4. Work out which classes and methods you need (see "Finding the right code").
5. Write a script file, then run it and read the output.

Run `mutiny` with no arguments for the authoritative command list. This file can go out of date; that output cannot.

## Where scripts go

```
%LOCALAPPDATA%\mutiny\app\<Name>\
  log              everything the injected DLL logs, including @Log output from scripts
  mods\<name>      persistent effects, these files are monitored by the injected DLL for changes and are automatically re-executed when changed
  mods\on-update-<name>  a mod that runs from the top on every frame of the game (see below)
  scripts\<name>   unliks mods, only executed when requested via `mutiny <PID> run-script <SCRIPT_NAME>`.
```

`<Name>` is the game's exe name without `.exe`. Mods and scripts have **no extension**.

Which directory to use is decided by *lifetime*, not content - both hold the same language:

- **A question** ("what's the player's health?") goes in `scripts\`. Run it with
  `mutiny <PID> run-script <name>`; its output comes back on stdout.
- **An effect that must persist** ("keep me at full health") goes in `mods\`. It starts running by
  itself as soon as you write the file, and re-runs from the top every time you change the text.

Writing a file into `mods\` starts it immediately.

A mod whose name starts with **`on-update-`** is an **update mod**: instead of running once when
written, it runs from the top on every frame of the game, from inside Unity's `Update`. Use it
for effects that must be re-applied continuously ("keep stamina full"). Rules that differ from
a normal mod:

- Keep it short: it runs every frame, on the main thread, so its cost is paid every frame.
- **`@Log` is an error in an update mod** - a line per frame would bury the log. Use
  `@UpdateResult(...)` instead: same arguments as `@Log`, but it *ends this frame's run* with
  that text as the frame's result, and the result only reaches the log when it **changes**. So
  `@UpdateResult("health ", h)` logs once per distinct value, not once per frame - that is how
  you debug an update mod.
- `@Rerun` is an error (the next frame is the rerun). `@IsFirstRun()` is always 0. `@Exit` just
  ends this frame's run.
- Nothing survives between frames; state lives in the game, as with `@Rerun`.
- An error does not stop it: it keeps running every frame, and errors are coalesced the same way
  as results - logged when they first happen, again only if they change, and
  `<name>: recovered` when a frame finishes cleanly again. So an update mod that fails until the
  level has loaded is fine and needs no guard.

## Finding the right code

`mutiny <PID> run-script @decomp` gives you tab-separated lines:

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

Private field names can differ between versions of a game (or of the .NET runtime it ships):
`@HasField(obj, "name")` returns 1 or 0 at runtime, so a mod can branch on which name exists
instead of failing with "has no field". There is no equivalent for methods, because a method
name alone doesn't identify one when it has overloads.

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
    set n = n + 1
continue                    // `continue` jumps back to `loop`; it ENDS the loop body

fn name(a, b) { @Log(a) }   // functions

Input.GetKeyDown(.Space)    // enum literal: `.Name`, resolved against the parameter's enum
var key = .Space            // it can be stored; it only becomes a value when passed to .NET
```

Things that will surprise you:

- **`loop` ... `continue` is the loop.** `loop` marks the top, `continue` jumps back to it, and
  `break` exits. The body is not brace-wrapped. Variables declared in the body are dropped at
  the end of every iteration; variables declared in an `if` block stay visible after it.
- **There is no way to sleep or wait inside a script.** Scripts run on the game's main thread
  and the game is frozen until the script finishes, so a loop that polls for a condition freezes
  the game forever. To wait, a mod calls `@Rerun(ms)`: that ends the script and runs it again
  from the top after `ms` milliseconds, with the game running in between. `@IsFirstRun()` is 1
  on the first run and 0 on every rerun, so you can log once instead of every time.
- **A second `loop` in the same block is rejected** with "cannot loop inside loop". Putting one
  inside an `if` block is not caught by that check, but nothing tests it and `break`/`continue`
  across that boundary is unexplored — so write one loop at a time.
- **No `else` yet.** Write a second `if` with the inverted condition.
- **A `const` field cannot be assigned**, only read. `@LogClass` marks each field `mutable`,
  `readonly` or `const`.
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
Root <- Statement*
Statement
   <- if LPAREN Expr RPAREN Block
    / loop
    / break
    / continue
    / fn IDENTIFIER ParamDeclList Block
    / var IDENTIFIER EQUAL Expr
    / set Reference EQUAL Expr
    / Expr

Reference
   <- IDENTIFIER (DOT IDENTIFIER)*

Expr <- ExprBinaryCompare
ExprBinaryCompare <- ExprBinaryMath (BinaryOpComparison ExprBinaryMath)*
ExprBinaryMath <- ExprSingle (BinaryOpMath ExprSingle)*
ExprSingle <- PrimaryTypeExpr ExprSuffix*

ExprSuffix
   <- LBRACKET Expr RBRACKET
    / DOT IDENTIFIER
    / ArgList

PrimaryTypeExpr
   <- IDENTIFIER
    / BUILTIN ArgList
    / LPAREN Expr RPAREN
    / NUMBER
    / STRINGLITERAL
    / EnumLiteral

EnumLiteral <- DOT IDENTIFIER

ArgList <- LPAREN (Expr COMMA)* Expr? RPAREN

Block <- LBRACE Statement* RBRACE

ParamDeclList <- LPAREN (IDENTIFIER COMMA)* IDENTIFIER? RPAREN

BinaryOpMath        <- "+" / "-" / "/"
BinaryOpComparison  <- "==" / "!=" / "<" / "<=" / ">" / ">="
NUMBER              <- "1" (integer) / "1.5" (float)
```

`ExprSuffix`'s `LBRACKET Expr RBRACKET` is array indexing — it parses but is **not implemented**,
so indexing fails at runtime. Everything else above works.

A `Statement` that is a bare `Expr` is only legal if the expression produces no value; wrap
anything that returns something in `@Discard`.

Two precedence levels only: math binds tighter than comparison. That operator list is exhaustive
**as of today** — the language is young and still being built out, so these are gaps rather than
deliberate exclusions, and they will likely be filled in over time:

- **No `*` yet.** Division exists, multiplication doesn't. Use repeated addition, or restructure
  to avoid needing it.
- **No `&&` or `||` yet.** Nest `if`s instead.
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
| `@TryClass(a.B)` | an **assembly field** | same; returns nothing instead of erroring if the class is absent |
| `@ClassOf(o)` | an object | the class of a live object |
| `@LogClass(c)` | a class | prints its fields and methods |
| `@Log(...)` | any number of anything | concatenates them; an error in an update mod |
| `@UpdateResult(...)` | any number of anything | update mods only: ends the run with the concatenation as this frame's result, logged only when it changes |
| `@ToString(v)` | anything | |
| `@IsNull(v)` / `@NotNull(v)` | anything | return an integer 0 or 1 |
| `@Assert(v)` | an integer | |
| `@Discard(v)` | anything | the only way to throw away a return value |
| `@Exit()` / `@Nothing()` | no arguments | |
| `@Rerun(ms)` | an integer | mods only (not update mods): exit now, run again from the top after `ms` milliseconds |
| `@IsFirstRun()` | no arguments | integer 1 on the first run, 0 on a rerun (always 0 in an update mod) |
| `@HasField(obj, "name")` | an object and a **string literal** | integer 1 if the object's class has a field with that name, else 0 |

`@Log` output goes to the log, and also back to you over the pipe when the script was started
with `run-script`.

## Rules that prevent crashes

These are not style advice. Each one is a way to take the game down.

1. **Overloads are chosen by the kinds of your arguments, strictly.** A method is looked up by
   name and argument count, then every candidate is checked against what you passed: an integer
   fits an integer parameter, a float a `float`/`double`, a string a `string`, an enum literal
   an enum. Exactly one candidate must fit; none is an error that lists the candidates and their
   parameter types, and *two* fitting is an "ambiguous overloads" error rather than a guess -
   `Foo(int)` next to `Foo(long)` cannot be called with an integer literal today. An integer is
   also accepted by a `float`/`double` parameter, but only when no exact candidate exists.
   An enum parameter takes an enum literal only: `GetKeyDown(.Space)`, never `GetKeyDown(32)`.
   Objects cannot be passed as arguments yet.

2. **Argument values are checked against the declared parameter type.** `float`, `double`, and
   every integer width convert correctly, and a value that doesn't fit stops the script with a
   message naming the value and the type, instead of silently truncating — passing 70000 to a
   `short` tells you so rather than quietly becoming 4464. The game is unaffected either way, so
   this is a safe thing to hit and correct. `Heal(100)` and `Heal(87.5)` on a `Heal(float)` both
   work.

   **Enums**: write them as `.Name` (`Input.GetKeyDown(.Space)`); an unknown name is an error
   naming the enum, and an integer is not accepted at all. (`[Flags]` combinations cannot be
   written yet.)

3. **Null-check before dereferencing.** A player object may not exist yet at the moment your
   script runs. Check with `@IsNull` / `@NotNull`; in a mod, `@Rerun(2000)` to try again later,
   as in the example below. Do not poll for it in a loop: the game is frozen while your script
   runs.

4. **Prefer reading before writing.** Read a value and `@Log` it first to confirm you have the
   right object and the units you expect, then write.

5. **Set a value, don't accumulate one.** Read the current value, compute the difference, and
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

var player = SemiFunc.PlayerAvatarGetFromSteamID("76561197960287930")
if (@IsNull(player)) {
    if (@IsFirstRun()) { @Log("waiting for the player...") }
    @Rerun(2000)
}
@LogClass(@ClassOf(player.playerHealth))
player.playerHealth.Heal(99999999, 0)
@Log("healed")
```

Note what it does before touching anything: names the assembly, resolves the class explicitly,
checks the object exists instead of assuming it, and logs the class so the member names are
confirmed rather than guessed.
