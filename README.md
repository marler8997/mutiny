# Mutiny

A scriptable mod tool for Unity games. Edit your mods while you play, no restart.

# Install

Download and run [MutinySetup.exe](https://github.com/marler8997/mutiny/releases/latest/download/MutinySetup.exe). It installs to `%LOCALAPPDATA%\mutiny`, adds the `mutiny` command to your PATH, and puts Mutiny in the Start Menu.

# How

Play any Unity game like normal. Whenever you like, open Mutiny and attach it to the running game. From then on, Mutiny automatically loads any files saved to the game's `mods` folder. Every edit is automatically reloaded.

The same is available from the command line, for scripts and AI agents:

```sh
# list running Unity games and whether Mutiny is attached
mutiny scan

# attach to a running game by PID
mutiny <PID> attach

# or start a game with Mutiny already attached
mutiny start <EXE>

# run a one-off script and print what it logs
mutiny <PID> run-script <NAME>

# turn a mod off or on, the same as its checkbox in the in-game panel
mutiny <PID> disable-mod <NAME>
mutiny <PID> enable-mod <NAME>
```

Everything Mutiny writes lives under one directory per app, named after its exe without the extension:

```
%LOCALAPPDATA%\mutiny\app\<Name>\
  exepath          the path to the executable
  log              what Mutiny logs from inside the game, including @Log output from your scripts
  mods\<name>      mods, run from the top on every frame
  scripts\<name>   one-off scripts, inert until you ask for them by name
  decomp\          the game's code, one file per type, kept up to date by `mutiny decomp <Name>`
  stdout.txt       captured only when Mutiny starts the game for you
  stderr.txt
```

`mutiny decomp <Name>` keeps that `decomp` directory up to date with the game: it reads the game's own
runtime without needing the game to be running and writes every assembly out, laid out the way a
script names things, i.e. `asm.Some.Namespace.Type` is `Assembly-CSharp\Some.Namespace.Type.cs`,
with every field and method signature the way a script calls it and, on mono games, every
method's body as IL.

It is idempotent and rewrites only the assemblies the game changed, so run it before reading
the code in cases where the game may have been updated since the last time it ran.

The difference between the two directories is *when they run*, not what's in them — both hold the same script language. A file in `mods\` runs by itself and re-runs whenever you edit it, which is what you want for a persistent effect like godmode. A file in `scripts\` does nothing until `mutiny run-script` names it, and its output comes back to your terminal instead of only going to the log, which is what you want for a one-off question like "what is the player's health right now".

# Example Mod

A mod runs from the top on every frame of the game. This one keeps the player's stamina full in
the game "PEAK":

```typescript
// save this to %LOCALAPPDATA%\mutiny\app\PEAK\mods\stamina
@Section(.update)
var game = @Assembly("Assembly-CSharp")
var Character = @Class(game.Character)
if (Character.get_localCharacterExists() == 0) { @Exit("no character") }
var me = Character.localCharacter
me.data.set_currentStamina(me.GetMaxStamina())
```

`@Exit(...)` ends the frame's run and the text is the mod's status, shown in the in-game panel
and logged whenever it changes:

```
info|mod 'stamina' loaded (250 bytes)
info|stamina: no character
info|stamina: recovered
```

To turn a mod off, untick it in the in-game panel, run `mutiny <PID> disable-mod stamina`, or
delete the file. A mod that changes something the game won't put back on its own can undo
itself with a `@Section(.disable)` part, which runs once when the mod is turned off, deleted or
edited; `mutiny-agent.md` has the details.
