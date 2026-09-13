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
  stdout.txt       captured only when Mutiny starts the game for you
  stderr.txt
```

A name starting with `@` is a builtin that needs no file at all:

- `mutiny <PID> run-script @assemblies` prints the assemblies the game has loaded, one per line.
- `mutiny <PID> run-script @decomp` prints where the game's code lives — the runtime kind, the exe, and each loaded assembly with its path on disk (or the `GameAssembly.dll` path, for il2cpp games where the assemblies have no separate files). Tab-separated, meant to be fed to other tools.

The difference between the two directories is *when they run*, not what's in them — both hold the same script language. A file in `mods\` runs by itself and re-runs whenever you edit it, which is what you want for a persistent effect like godmode. A file in `scripts\` does nothing until `mutiny run-script` names it, and its output comes back to your terminal instead of only going to the log, which is what you want for a one-off question like "which assemblies are loaded".

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
