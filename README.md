# Mutiny

A scriptable dll injector for modding Unity games.

# How

Launch the game like normal. At any point you can inject `Mutiny.dll`. This can be done via a CLI:

```sh
# scan every process to find a game/PID you want to inject
mutiny scan

# get Mutiny running in the game using the PID
mutiny <PID> attach

# run a one-off script and print what it logs
mutiny <PID> run-script <NAME>
```

Once injected, Mutiny will continuously monitor the directory `%LOCALAPPDATA%\mutiny\app\InsertGameNameHere\mods` for script files and reload them when they change.

Everything Mutiny writes lives under one directory per app, named after its exe without the extension:

```
%LOCALAPPDATA%\mutiny\app\<Name>\
  log              what the injected DLL logs, including @Log output from your scripts
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
var game = @Assembly("Assembly-CSharp")
var Character = @Class(game.Character)
if (Character.get_localCharacterExists() == 0) { @Exit("no character") }
var me = Character.localCharacter
me.data.set_currentStamina(me.GetMaxStamina())
@Exit("enabled")
```

`@Exit(...)` ends the frame's run and the text is the mod's status, shown in the in-game panel
and logged whenever it changes:

```
info|mod 'stamina' loaded (250 bytes)
info|stamina: no character
info|stamina: enabled
```

To turn a mod off, add `@Exit("disabled")` as its first line and save, or delete the file.
