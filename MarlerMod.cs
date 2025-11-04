using System;
using System.Collections.Generic;
using System.Reflection;

namespace MarlerMod
{
    [BepInEx.BepInPlugin("com.marler.upgrademod", "Marler Upgrade Mod", "1.0.0")]
    public class Plugin : BepInEx.BaseUnityPlugin
    {
        private static BepInEx.Logging.ManualLogSource logger;
        private static bool commandsRegistered = false;

        private void Awake()
        {
            logger = Logger;
            logger.LogInfo("=== MARLER UPGRADE MOD LOADED ===");

            try
            {
                logger.LogInfo("Applying Harmony patches...");
                HarmonyLib.Harmony harmony = new HarmonyLib.Harmony("com.marler.upgrademod");
                harmony.PatchAll();
                logger.LogInfo("Harmony patches applied successfully!");
            }
            catch (Exception e)
            {
                logger.LogError("Failed to apply Harmony patches: " + e.Message);
                logger.LogError(e.StackTrace);
            }
        }

        [HarmonyLib.HarmonyPatch(typeof(DebugCommandHandler), "Awake")]
        public class DebugCommandHandler_Awake_Patch
        {
            static void Postfix()
            {
                if (commandsRegistered)
                {
                    logger.LogInfo("Commands already registered, skipping...");
                    return;
                }

                logger.LogInfo("Registering upgrade commands...");

                try
                {
                    RegisterUpgradeCommands();
                    commandsRegistered = true;
                    logger.LogInfo("All commands registered successfully!");
                }
                catch (Exception e)
                {
                    logger.LogError("Failed to register commands: " + e.Message);
                    logger.LogError(e.StackTrace);
                }
            }
        }

        private static void RegisterUpgradeCommands()
        {
            DebugCommandHandler.ChatCommand sprintCmd = new DebugCommandHandler.ChatCommand(
                "sprint",
                "Set sprint upgrade level. Usage: sprint <level>",
                new Action<bool, string[]>(ExecuteSprintCommand),
                null, null, false
            );
            DebugCommandHandler.instance.Register(sprintCmd);
            logger.LogInfo("Sprint command registered!");

            DebugCommandHandler.ChatCommand staminaCmd = new DebugCommandHandler.ChatCommand(
                "stamina",
                "Set stamina upgrade level. Usage: stamina <level>",
                new Action<bool, string[]>(ExecuteStaminaCommand),
                null, null, false
            );
            DebugCommandHandler.instance.Register(staminaCmd);
            logger.LogInfo("Stamina command registered!");

            DebugCommandHandler.ChatCommand healthCmd = new DebugCommandHandler.ChatCommand(
                "health",
                "Set health upgrade level. Usage: health <level>",
                new Action<bool, string[]>(ExecuteHealthCommand),
                null, null, false
            );
            DebugCommandHandler.instance.Register(healthCmd);
            logger.LogInfo("Health command registered!");

            DebugCommandHandler.ChatCommand strengthCmd = new DebugCommandHandler.ChatCommand(
                "strength",
                "Set strength upgrade level. Usage: strength <level>",
                new Action<bool, string[]>(ExecuteStrengthCommand),
                null, null, false
            );
            DebugCommandHandler.instance.Register(strengthCmd);
            logger.LogInfo("Strength command registered!");
        }

        private enum UpgradeKind
        {
            Sprint,
            Stamina,
            Health,
            Strength,
        }

        private static void ExecuteSprintCommand(bool fromServer, string[] args)
        {
            ExecuteUpgradeCommand(UpgradeKind.Sprint, args);
        }

        private static void ExecuteStaminaCommand(bool fromServer, string[] args)
        {
            ExecuteUpgradeCommand(UpgradeKind.Stamina, args);
        }

        private static void ExecuteHealthCommand(bool fromServer, string[] args)
        {
            ExecuteUpgradeCommand(UpgradeKind.Health, args);
        }

        private static void ExecuteStrengthCommand(bool fromServer, string[] args)
        {
            ExecuteUpgradeCommand(UpgradeKind.Strength, args);
        }

        private static void ExecuteUpgradeCommand(UpgradeKind kind, string[] args)
        {
            if (args.Length < 1)
            {
                SendConsoleResponse("Usage: " + kind.ToString().ToLower() + " <level>");
                return;
            }
            int desiredLevel;
            if (!int.TryParse(args[0], out desiredLevel))
            {
                SendConsoleResponse("ERROR: '" + args[0] + "' is not a valid integer");
                return;
            }

            List<string> steamIDs = GetAllPlayerSteamIDs();
            if (steamIDs.Count == 0)
            {
                logger.LogWarning("failed to get any player Steam IDs");
                SendConsoleResponse("failed to get any player Steam IDs");
                return;
            }

            logger.LogInfo("found " + steamIDs.Count + " player(s) to upgrade");

            int successCount = 0;
            int failCount = 0;

            foreach (string steamID in steamIDs)
            {
                logger.LogInfo("Upgrading player " + steamID);

                int currentLevel = GetCurrentLevel(kind, steamID);
                if (currentLevel == -1)
                {
                    failCount++;
                    continue;
                }

                int newLevel = SetNewLevel(kind, steamID, desiredLevel, currentLevel);
                if (newLevel == -1)
                {
                    failCount++;
                    continue;
                }

                if (newLevel == desiredLevel)
                {
                    logger.LogInfo(string.Format("SUCCESS: {0} set to level {1} for player {2}", kind, desiredLevel, steamID));
                    successCount++;
                }
                else
                {
                    logger.LogWarning(string.Format("UNEXPECTED: {0} set to {1} but returned {2} for player {3}", kind, desiredLevel, newLevel, steamID));
                    successCount++;
                }
            }

            string response = string.Format("{0} upgraded to level {1} for {2} player(s)", kind, desiredLevel, successCount);
            if (failCount > 0)
            {
                response += string.Format(" ({0} failed)", failCount);
            }

            SendConsoleResponse(response);
        }

        private static int GetCurrentLevel(UpgradeKind kind, string steamID)
        {
            try
            {
                return ApplyUpgrade(kind, steamID, 0);
            }
            catch (Exception e)
            {
                logger.LogError("Error getting current " + kind + " level: " + e.Message);
                logger.LogError(e.StackTrace);
                SendConsoleResponse("ERROR: Failed to get current " + kind + " level");
                return -1;
            }
        }

        private static int SetNewLevel(UpgradeKind kind, string steamID, int desiredLevel, int currentLevel)
        {
            int diff = desiredLevel - currentLevel;
            try
            {
                return ApplyUpgrade(kind, steamID, diff);
            }
            catch (Exception e)
            {
                logger.LogError("Error setting " + kind + " level: " + e.Message);
                logger.LogError(e.StackTrace);
                SendConsoleResponse("ERROR: Failed to set " + kind + " level");
                return -1;
            }
        }

        private static int ApplyUpgrade(UpgradeKind kind, string steamID, int change)
        {
            switch (kind) {
                case UpgradeKind.Sprint: return PunManager.instance.UpgradePlayerSprintSpeed(steamID, change);
                case UpgradeKind.Stamina: return PunManager.instance.UpgradePlayerEnergy(steamID, change);
                case UpgradeKind.Health: return PunManager.instance.UpgradePlayerHealth(steamID, change);
                case UpgradeKind.Strength: return PunManager.instance.UpgradePlayerGrabStrength(steamID, change);
                default: throw new ArgumentOutOfRangeException("kind", kind, "Invalid upgrade kind");
            }
        }

        private static void SendConsoleResponse(string message)
        {
            // TODO: Implement actual console message display
            logger.LogInfo("Console message: " + message);
        }

        private static List<string> GetAllPlayerSteamIDs()
        {
            List<string> steamIDs = new List<string>();

            try
            {
                PlayerController[] players = UnityEngine.Object.FindObjectsOfType<PlayerController>();
                logger.LogInfo("Found " + players.Length + " PlayerController(s)");

                foreach (PlayerController player in players)
                {
                    Photon.Pun.PhotonView photonView = player.GetComponent<Photon.Pun.PhotonView>();
                    if (photonView != null && photonView.Owner != null)
                    {
                        string steamID = photonView.Owner.UserId;
                        logger.LogInfo("Found player - UserId: " + steamID);
                        steamIDs.Add(steamID);
                    }
                }
            }
            catch (Exception e)
            {
                logger.LogError("Failed to get all player Steam IDs: " + e.Message);
                logger.LogError(e.StackTrace);
            }

            return steamIDs;
        }
    }
}
