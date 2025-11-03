using BepInEx;
using BepInEx.Logging;
using UnityEngine;
using HarmonyLib;
using System;

namespace MarlerMod
{
    [BepInPlugin("com.marler.upgrademod", "Marler Upgrade Mod", "1.0.0")]
    public class Plugin : BaseUnityPlugin
    {
        private static ManualLogSource logger;
        private static bool commandsRegistered = false;

        private void Awake()
        {
            logger = Logger;
            logger.LogInfo("=== MARLER UPGRADE MOD LOADED ===");

            try
            {
                logger.LogInfo("Applying Harmony patches...");
                Harmony harmony = new Harmony("com.marler.upgrademod");
                harmony.PatchAll();
                logger.LogInfo("Harmony patches applied successfully!");
            }
            catch (Exception e)
            {
                logger.LogError("Failed to apply Harmony patches: " + e.Message);
                logger.LogError(e.StackTrace);
            }
        }

        [HarmonyPatch(typeof(DebugCommandHandler), "Awake")]
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
        }

        private enum UpgradeKind
        {
            Sprint,
            Stamina,
            Health
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

        private static void ExecuteUpgradeCommand(UpgradeKind kind, string[] args)
        {
            string steamID = GetLocalPlayerSteamID();
            if (string.IsNullOrEmpty(steamID))
            {
                logger.LogWarning("Failed to get Steam ID");
                SendConsoleResponse("Failed to get Steam ID");
                return;
            }

            logger.LogInfo("Using Steam ID: " + steamID);

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

            int currentLevel = GetCurrentLevel(kind, steamID);
            if (currentLevel == -1)
            {
                return;
            }

            int newLevel = SetNewLevel(kind, steamID, desiredLevel, currentLevel);
            if (newLevel == -1)
            {
                return;
            }

            if (newLevel == desiredLevel)
            {
                logger.LogInfo(string.Format("SUCCESS: {0} set to level {1}", kind, desiredLevel));
                SendConsoleResponse(string.Format("{0} upgraded to level {1}", kind, desiredLevel));
            }
            else
            {
                logger.LogWarning(string.Format("UNEXPECTED: {0} set to {1} but returned {2}", kind, desiredLevel, newLevel));
                SendConsoleResponse(string.Format("{0} is now at level {1} (expected {2})", kind, newLevel, desiredLevel));
            }
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
            if (kind == UpgradeKind.Sprint)
            {
                return PunManager.instance.UpgradePlayerSprintSpeed(steamID, change);
            }
            else if (kind == UpgradeKind.Stamina)
            {
                return PunManager.instance.UpgradePlayerEnergy(steamID, change);
            }
            else if (kind == UpgradeKind.Health)
            {
                return PunManager.instance.UpgradePlayerHealth(steamID, change);
            }
            else
            {
                throw new ArgumentOutOfRangeException("kind", kind, "Invalid upgrade kind");
            }
        }

        private static void SendConsoleResponse(string message)
        {
            // TODO: Implement actual console message display
            logger.LogInfo("Console message: " + message);
        }

        private static string GetLocalPlayerSteamID()
        {
            // Method 1: Try PhotonView on local player
            string steamID = TryGetSteamIDFromPhoton();
            if (!string.IsNullOrEmpty(steamID))
            {
                return steamID;
            }

            // Method 2: Try SteamManager
            steamID = TryGetSteamIDFromSteamManager();
            if (!string.IsNullOrEmpty(steamID))
            {
                return steamID;
            }

            logger.LogWarning("All methods failed to get Steam ID");
            return string.Empty;
        }

        private static string TryGetSteamIDFromPhoton()
        {
            try
            {
                PlayerController[] players = UnityEngine.Object.FindObjectsOfType<PlayerController>();
                logger.LogInfo("Found " + players.Length + " PlayerController(s)");

                foreach (PlayerController player in players)
                {
                    Photon.Pun.PhotonView photonView = player.GetComponent<Photon.Pun.PhotonView>();
                    if (photonView != null && photonView.IsMine && photonView.Owner != null)
                    {
                        logger.LogInfo("Found local player - UserId: " + photonView.Owner.UserId);
                        return photonView.Owner.UserId;
                    }
                }
            }
            catch (Exception e)
            {
                logger.LogInfo("PhotonView method failed: " + e.Message);
            }

            return string.Empty;
        }

        private static string TryGetSteamIDFromSteamManager()
        {
            try
            {
                Type steamManagerType = Type.GetType("Steamworks.SteamManager, Assembly-CSharp");
                if (steamManagerType == null)
                {
                    return string.Empty;
                }

                System.Reflection.PropertyInfo initProp = steamManagerType.GetProperty("Initialized");
                if (initProp == null)
                {
                    return string.Empty;
                }

                object initialized = initProp.GetValue(null, null);
                if (initialized is bool && (bool)initialized)
                {
                    Type steamUserType = Type.GetType("Steamworks.SteamUser, Assembly-CSharp");
                    if (steamUserType == null)
                    {
                        return string.Empty;
                    }

                    System.Reflection.MethodInfo getIdMethod = steamUserType.GetMethod("GetSteamID");
                    if (getIdMethod == null)
                    {
                        return string.Empty;
                    }

                    object steamID = getIdMethod.Invoke(null, null);
                    if (steamID != null)
                    {
                        string id = steamID.ToString();
                        logger.LogInfo("Got Steam ID from SteamManager: " + id);
                        return id;
                    }
                }
            }
            catch (Exception e)
            {
                logger.LogInfo("SteamManager method failed: " + e.Message);
            }

            return string.Empty;
        }
    }
}
