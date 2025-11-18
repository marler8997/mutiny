# Mutiny

A scriptable dll injector for modding Unity games.

# How

Launch the game like normal. At any point you can inject `Mutiny.dll`. Once injected, Mutiny will continuously monitor the directory `C:\mutiny\mods\InsertGameNameHere` for script files and reload them when they change.

# Example Script

Here's a hacky example script I created on the fly to make myself and a couple friends "GODS" in the game "R.E.P.O".

```typescript
// save this script to C:\mutiny\mods\REPO\godmode
var Steamworks = @Assembly("Facepunch.Steamworks.Win64")
var SteamClient = @Class(Steamworks.Steamworks.SteamClient)

@Log("waiting for steam id...")
var attempt = 1
loop
    if (SteamClient.get_IsValid()) { break }
    @Log("  no steam id yet, attempt ", attempt)
    attempt = attempt + 1
    yield 2000
continue

// comment/uncomment the following lines to re-run the script for Danny/Zach, their
// upgrades won't apply until the next level.
var steam_id = @ToString(SteamClient.get_SteamId().Value)
//var steam_id = @ToString(76561197963995344) // danny
//var steam_id = @ToString(76561199195454462) // Zach
@Log("steam id is '", steam_id, "'")

var game = @Assembly("Assembly-CSharp")

var PunManager = @Class(game.PunManager)
var punManagerInstance = PunManager.instance

var value = 0
var diff = 0

value = punManagerInstance.UpgradePlayerSprintSpeed(steam_id, 0)
@Log("Sprint current=", value)
diff = 7 - value
value = punManagerInstance.UpgradePlayerSprintSpeed(steam_id, diff)
@Log("Sprint new   =", value)

value = punManagerInstance.UpgradePlayerEnergy(steam_id, 0)
@Log("Stamina current=", value)
diff = 1000 - value
value = punManagerInstance.UpgradePlayerEnergy(steam_id, diff)
@Log("Stamina new    =", value)

value = punManagerInstance.UpgradePlayerHealth(steam_id, 0)
@Log("Health current=", value)
diff = 1000 - value
value = punManagerInstance.UpgradePlayerHealth(steam_id, diff)
@Log("Health new    =", value)

value = punManagerInstance.UpgradePlayerExtraJump(steam_id, 0)
@Log("Jump current=", value)
diff = 1000 - value
value = punManagerInstance.UpgradePlayerExtraJump(steam_id, diff)
@Log("Jump new    =", value)

value = punManagerInstance.UpgradePlayerThrowStrength(steam_id, 0)
@Log("Throw current=", value)
diff = 1 - value
value = punManagerInstance.UpgradePlayerThrowStrength(steam_id, diff)
@Log("Throw new    =", value)

value = punManagerInstance.UpgradePlayerGrabRange(steam_id, 0)
@Log("Range current=", value)
diff = 3 - value
value = punManagerInstance.UpgradePlayerGrabRange(steam_id, diff)
@Log("Range new    =", value)

value = punManagerInstance.UpgradePlayerGrabStrength(steam_id, 0)
@Log("Strength current=", value)
diff = 50 - value
value = punManagerInstance.UpgradePlayerGrabStrength(steam_id, diff)
@Log("Strength new    =", value)

var SemiFunc = @Class(game.SemiFunc)
var player = SemiFunc.PlayerAvatarGetFromSteamID(steam_id)
//@LogClass(@ClassOf(player.playerHealth))
player.playerHealth.Heal(99999999, 0)

// It's annoying to have to keep giving health to Danny/Zach so here you go guys!
var danny = SemiFunc.PlayerAvatarGetFromSteamID("76561197963995344")
danny.playerHealth.HealOther(99999999, 0)
var zach = SemiFunc.PlayerAvatarGetFromSteamID("76561199195454462")
zach.playerHealth.HealOther(99999999, 0)
```
