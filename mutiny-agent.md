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
  mods\<name>      a mod: runs from the top on every frame of the game (see below)
  scripts\<name>   unliks mods, only executed when requested via `mutiny <PID> run-script <SCRIPT_NAME>`.
```

`<Name>` is the game's exe name without `.exe`. Mods and scripts have **no extension**.

Which directory to use is decided by *lifetime*, not content - both hold the same language:

- **A question** ("what's the player's health?") or **a one-shot action** ("give me 1,000,000
  money", "unlock the door") goes in `scripts\`. Run it with `mutiny <PID> run-script <name>`;
  it runs exactly once, when asked, and its output comes back on stdout. A one-shot must not be
  a mod: a mod file persists, so it would run again on every game start.
- **An effect** ("keep me at full health", "unlimited jumps", "3x world speed") goes in `mods\`
  as a **mod**, `mods\<name>`. This is the default for anything a player asks to *have*. See
  "Mods" below.

Writing a new file into `mods\` loads and enables it immediately.

## Mods

A mod runs from the top on **every frame of the game**, inside Unity's `Update`. That
is all the mechanism is. One way to use it - and the one the examples below follow - is to
check what exists, put the value where you want it, and report; written that way it behaves
like an effect you have *added to the game* rather than a script you run:

- it applies as soon as its target exists and re-applies after anything the game does to undo
  it (a respawn, a scene load, a time-loop reset, the player picking up a new item), because
  every frame starts over and puts the value back;
- it needs no waiting logic - a frame where the target is missing just reports and the next
  frame looks again;
- its status reaches the log only when it **changes**, so the log reads like an event history,
  not a trace;
- it is on while the file exists; the player can turn it off from the in-game panel, and
  `mutiny <PID> disable-mod <name>` / `enable-mod <name>` do the same from the CLI.

Here's an example of a mod for "infinit stamina" in the game PEAK:

```
@Section(.update)
var game = @Assembly("Assembly-CSharp")
var Character = @Class(game.Character)
if (Character.get_localCharacterExists() == 0) { @Exit("no character") }
var me = Character.localCharacter
me.data.set_currentStamina(me.GetMaxStamina())
```

When this is written to "mods/stamina", here's what it can look like in the log:

```
13:54:46.239|98308|107484|PEAK|info|mod 'stamina' loaded (250 bytes)
13:55:01.418|98308|107484|PEAK|info|stamina: no character
13:55:01.799|98308|107484|PEAK|info|stamina: enabled
```

Rules that differ from a script:

- **`@Log` is an error** - a line per frame would bury the log. `@Exit(...)` takes the same arguments, **ends this frame's run**, and makes the text the frame's *result*; the result is logged only when it differs from the previous frame's. `@Exit()` with no arguments ends the frame silently.
- **Result text should be stable unless you want something in the log.** `@Exit("hp=", hp)` with a value that changes every frame logs every frame - exactly what `@Log` was banned for. Report *states*: when the frame did its job, just finish (the panel shows "enabled" and the log says `recovered` if the previous frame reported something); otherwise say why not ("no character", "waiting for player").
- Nothing survives between frames; state lives in the game.
- **An error never stops it.** The error is logged once just like `@Exit()` unless it changes. `<name>: recovered` is logged when the error goes away. So a mod that fails until the level has loaded is fine as-is - but a guard with `@Exit` is better, because it names the state instead of showing an error.
- Keep it short: its cost is paid every frame, on the main thread.

### Sections

A mod file is made of **sections**, one per hook, each introduced by a `@Section(.name)` line
at the top level of the file (never inside `{ }`). Code outside a section is an error. Sections
have no knowledge or interaction with each other, they are completely independent:

```
@Section(.update)
var game = @Assembly("Assembly-CSharp")
var Time = @Class(game.UnityEngine.Time)
Time.set_timeScale(3)

@Section(.disable)
var game = @Assembly("Assembly-CSharp")
var Time = @Class(game.UnityEngine.Time)
Time.set_timeScale(1)
```

- `.update` runs every frame - the section almost every mod has.
- `.disable` runs once when the mod stops: it is turned off, the file is deleted, or the
  file is edited (the old text's `.disable` runs before the new text starts). Use it to undo
  what the mod did. Nothing carries over from `.update`, so it can only restore to a value it
  knows - declare what it needs again, as above.

Each section is a complete script on its own: variables and `@Class` lookups do not carry
across sections, so repeat them. Any section may be left out (an empty file is a mod that does
nothing), each may appear once, and only comments may come before the first `@Section`.
`@Exit(...)` text and errors from `.disable` go to the log with the hook name; `.update`
behaves as described above. Error line
numbers are file line numbers. Scripts in `scripts\` have no sections: a script is the whole
file.

### Examples

Real mods from three games, as written. They show the shape; they are not rules. Note
that none of them puts its own name in an `@Exit`: the log prefixes every result with
the mod's name already.

PEAK, fly - a mod sees every frame, so "while the button is held" is an `if` on the
input state; the result carries the one thing the player has to know:

```
@Section(.update)
var jumpImpulse = 1080

var game = @Assembly("Assembly-CSharp")
var Character = @Class(game.Character)
var CharacterInput = @Class(game.CharacterInput)
if (Character.get_localCharacterExists() == 0) { @Exit("no character") }
var me = Character.localCharacter
var d = me.data
var a = me.refs.afflictions
var mv = me.refs.movement

// 0. jump strength
set mv.jumpImpulse = jumpImpulse

// 1. unlimited air jumps
set a.totalExtraJumps = 999999
set d.extraJumps = 999999

// 2. auto-jump while held
if (CharacterInput.action_jump.IsPressed() == 1) {
    set d.isJumping = 0
    set d.sinceJump = 10
    mv.TryToJump()
}
@Exit("enabled: hold jump to fly")
```

Outer Wilds, jetpack - the knobs are `var`s at the top with the game's defaults noted; the
player edits a number and saves, and the changed file reloads the mod:

```
// transThrust: thrust while holding the jetpack   (game default = 6)
// boostThrust: the boost burst                    (game default = 23)
@Section(.update)
var transThrust = 18
var boostThrust = 70

var game = @Assembly("Assembly-CSharp")
var Locator = @Class(game.Locator)
var ctrl = Locator.GetPlayerController()
if (@IsNull(ctrl)) { @Exit("waiting for player") }

var jet = ctrl._jetpackModel
if (@IsNull(jet)) { @Exit("waiting for jetpack") }

set jet._maxTranslationalThrust = transThrust
set jet._boostThrust = boostThrust
```

Outer Wilds, world speed - the mod's own header explains why it skips frames where
`timeScale` is 0:

```
// === TIME LORD === (runs every frame)
// World-speed dial for the whole physics-simulated solar system.
// EDIT `speed` below, then SAVE.  1 = normal, 2-10 = fast-forward, 0.2 = slow-mo.
//
// It SKIPS when timeScale is 0, so the pause menu still works and you no longer
// have to re-save after pausing (the old normal-mod version needed that).
// To turn off: delete this file, or set speed = 1 and save.

@Section(.update)
var speed = 1

var core = @Assembly("UnityEngine.CoreModule")
var Time = @Class(core.UnityEngine.Time)
var cur = Time.get_timeScale()

// leave 0 alone (that is the pause menu); otherwise hold it at `speed`
if (cur != 0) { Time.set_timeScale(speed) }
```

Outer Wilds, god mode - the header says what it does, what it does not, and what stays
behind when it is turned off:

```
// === GOD MODE === (runs every frame, survives time-loop resets)
//   1. Invincibility   - no damage / impact / suffocation death
//   2. Infinite fuel   - jetpack never runs dry
//   3. Infinite oxygen - never suffocate
//   4. Infinite boost  - the jetpack boost meter never drains
//
// Does NOT stop scripted deaths (sun, black hole) or the ~22-min supernova reset.
// To turn off: delete this file. (Invincibility flag clears on the next loop reset.)

@Section(.update)
var game = @Assembly("Assembly-CSharp")
var Locator = @Class(game.Locator)
var ctrl = Locator.GetPlayerController()
if (@IsNull(ctrl)) { @Exit("waiting for player") }

var pr = ctrl._playerResources
if (@IsNull(pr)) { @Exit("waiting for resources") }

var PR = @ClassOf(pr)

if (pr.IsInvincible() == 0) {
    pr.ToggleInvincibility()
}
set pr._currentFuel = PR._maxFuel
set pr._currentOxygen = PR._maxOxygen
var jet = ctrl._jetpackModel
if (@NotNull(jet)) {
    set jet._boostChargeFraction = 1
}
```


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
  the game forever. Waiting is what a mod is for: it runs again next frame, so it checks for the
  condition and ends the frame with `@Exit("waiting for ...")` until it holds.
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
| `@Log(...)` | any number of anything | concatenates them; an error in a mod |
| `@Exit(...)` | any number of anything | ends the run; with arguments, the concatenation is the run's outcome: in a mod this frame's result (logged only when it changes), elsewhere a log line |
| `@ToString(v)` | anything | |
| `@IsNull(v)` / `@NotNull(v)` | anything | return an integer 0 or 1 |
| `@Assert(v)` | an integer | |
| `@Discard(v)` | anything | the only way to throw away a return value |
| `@Nothing()` | no arguments | |
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
   script runs. Check with `@IsNull` / `@NotNull`; in a mod, exit the frame with
   `@Exit("waiting for player")`, as in the example below; in a script, report it and exit. Do
   not poll for it in a loop: the game is frozen while your script runs.

4. **Prefer reading before writing.** Read a value and `@Log` it first to confirm you have the
   right object and the units you expect, then write.

5. **Set a value, don't accumulate one.** Read the current value, compute the difference, and
   apply that - a mod re-runs whenever its file changes, and repeated addition compounds.

## Tell the player about these

- **How to tune an effect.** Edit the numbers at the top of its `.update` section in
  `mods\<name>` and save. If the mod changes something the game does not restore on its own,
  give it a `.disable` section that puts the value back, and say which of its changes stay
  behind after it is turned off.
- **`mutiny run-script` always exits 0**, even when the script failed. Read the output to find out
  whether it worked; do not trust the exit code.
- **A syntax error stops the whole script**, and the message names a line number and what was
  expected. Read it - the messages are specific.

## A worked example of a mod

A `mods\<name>` file that keeps the player at full health once they exist.

```
@Section(.update)
var game = @Assembly("Assembly-CSharp")
var SemiFunc = @Class(game.SemiFunc)

var player = SemiFunc.PlayerAvatarGetFromSteamID("76561197960287930")
if (@IsNull(player)) { @Exit("waiting for the player") }
var health = player.playerHealth
if (health.health < health.maxHealth) {
    health.Heal(health.maxHealth - health.health, 0)
}
```

Note what it does before touching anything: names the assembly, resolves the class explicitly,
checks the object exists instead of assuming it, and only writes when the value is off, so a
frame where nothing needs doing costs a comparison and no call into the game.
