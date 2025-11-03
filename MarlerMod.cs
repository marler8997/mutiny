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
        private static bool commandsRegistered = false;  // Prevent duplicate registration

        private void Awake()
        {
            logger = Logger;
            Logger.LogInfo("=== MARLER UPGRADE MOD LOADED ===");

            try
            {
                Logger.LogInfo("Applying Harmony patches...");
                Harmony harmony = new Harmony("com.marler.upgrademod");
                harmony.PatchAll();
                Logger.LogInfo("Harmony patches applied!");
            }
            catch (Exception e)
            {
                Logger.LogError("Failed to apply Harmony patches: " + e.Message);
                Logger.LogError(e.StackTrace);
            }
        }

        [HarmonyPatch(typeof(DebugCommandHandler))]
        [HarmonyPatch("Awake")]
        public class DebugCommandHandler_Awake_Patch
        {
            static void Postfix()
            {
                if (commandsRegistered)
                {
                    logger.LogInfo("Commands already registered, skipping...");
                    return;
                }

                logger.LogInfo("DebugCommandHandler.Awake() called - registering our commands!");

                try
                {
                    RegisterUpgradeCommands();
                    commandsRegistered = true;
                }
                catch (Exception e)
                {
                    logger.LogError("Failed in postfix: " + e.Message);
                    logger.LogError(e.StackTrace);
                }
            }
        }

        private static void RegisterUpgradeCommands()
        {
            logger.LogInfo("RegisterUpgradeCommands() started");

            try
            {
                DebugCommandHandler.ChatCommand sprintCmd = new DebugCommandHandler.ChatCommand(
                    "sprint",
                    "Set sprint upgrade level. Usage: sprint <level>",
                    new Action<bool, string[]>(ExecuteSprintCommand),
                    null, null, false
                );
                DebugCommandHandler.instance.Register(sprintCmd);
                logger.LogInfo("Sprint command registered!");

                DebugCommandHandler.ChatCommand energyCmd = new DebugCommandHandler.ChatCommand(
                    "energy",
                    "Set energy upgrade level. Usage: energy <level>",
                    new Action<bool, string[]>(ExecuteEnergyCommand),
                    null, null, false
                );
                DebugCommandHandler.instance.Register(energyCmd);
                logger.LogInfo("Energy command registered!");

                DebugCommandHandler.ChatCommand healthCmd = new DebugCommandHandler.ChatCommand(
                    "health",
                    "Set health upgrade level. Usage: health <level>",
                    new Action<bool, string[]>(ExecuteHealthCommand),
                    null, null, false
                );
                DebugCommandHandler.instance.Register(healthCmd);
                logger.LogInfo("Health command registered!");

                logger.LogInfo("All commands registered successfully!");
            }
            catch (Exception e)
            {
                logger.LogError("Failed to register commands: " + e.Message);
                logger.LogError(e.StackTrace);
            }
        }

        private static void ExecuteSprintCommand(bool fromServer, string[] args)
        {
            logger.LogInfo("ExecuteSprintCommand called!");

            if (args.Length < 1)
            {
                logger.LogInfo("Usage: sprint <level>");
                return;
            }

            int level;
            if (!int.TryParse(args[0], out level))
            {
                logger.LogInfo("Invalid level. Must be a number.");
                return;
            }

            try
            {
                string steamID = GetLocalPlayerSteamID();
                logger.LogInfo("Using Steam ID: " + steamID);

                if (string.IsNullOrEmpty(steamID))
                {
                    logger.LogError("Could not get Steam ID!");
                    return;
                }

                int result = PunManager.instance.UpgradePlayerSprintSpeed(steamID, level);
                logger.LogInfo(string.Format("Sprint upgraded to level {0} (result: {1})", level, result));
            }
            catch (Exception e)
            {
                logger.LogError("Error: " + e.Message);
                logger.LogError(e.StackTrace);
            }
        }

        private static void ExecuteEnergyCommand(bool fromServer, string[] args)
        {
            logger.LogInfo("ExecuteEnergyCommand called!");

            if (args.Length < 1)
            {
                logger.LogInfo("Usage: energy <level>");
                return;
            }

            int level;
            if (!int.TryParse(args[0], out level))
            {
                logger.LogInfo("Invalid level. Must be a number.");
                return;
            }

            try
            {
                string steamID = GetLocalPlayerSteamID();
                if (string.IsNullOrEmpty(steamID))
                {
                    logger.LogError("Could not get Steam ID!");
                    return;
                }

                int result = PunManager.instance.UpgradePlayerEnergy(steamID, level);
                logger.LogInfo(string.Format("Energy upgraded to level {0} (result: {1})", level, result));
            }
            catch (Exception e)
            {
                logger.LogError("Error: " + e.Message);
                logger.LogError(e.StackTrace);
            }
        }

        private static void ExecuteHealthCommand(bool fromServer, string[] args)
        {
            logger.LogInfo("ExecuteHealthCommand called!");

            if (args.Length < 1)
            {
                logger.LogInfo("Usage: health <level>");
                return;
            }

            int level;
            if (!int.TryParse(args[0], out level))
            {
                logger.LogInfo("Invalid level. Must be a number.");
                return;
            }

            try
            {
                string steamID = GetLocalPlayerSteamID();
                if (string.IsNullOrEmpty(steamID))
                {
                    logger.LogError("Could not get Steam ID!");
                    return;
                }

                int result = PunManager.instance.UpgradePlayerHealth(steamID, level);
                logger.LogInfo(string.Format("Health upgraded to level {0} (result: {1})", level, result));
            }
            catch (Exception e)
            {
                logger.LogError("Error: " + e.Message);
                logger.LogError(e.StackTrace);
            }
        }

        private static string GetLocalPlayerSteamID()
        {
            // Method 1: Check what keys PunManager actually has
            try
            {
                logger.LogInfo("Checking PunManager for player keys...");
                System.Reflection.FieldInfo[] punFields = typeof(PunManager).GetFields(
                    System.Reflection.BindingFlags.Public |
                    System.Reflection.BindingFlags.NonPublic |
                    System.Reflection.BindingFlags.Instance);

                foreach (var field in punFields)
                {
                    if (field.FieldType.IsGenericType &&
                        field.FieldType.GetGenericTypeDefinition() == typeof(System.Collections.Generic.Dictionary<,>))
                    {
                        logger.LogInfo("Found dictionary field: " + field.Name);
                        object dict = field.GetValue(PunManager.instance);
                        if (dict != null)
                        {
                            System.Collections.IEnumerable keys = (System.Collections.IEnumerable)dict.GetType().GetProperty("Keys").GetValue(dict, null);
                            logger.LogInfo("  Keys in dictionary:");
                            foreach (var key in keys)
                            {
                                logger.LogInfo("    - " + key.ToString());
                            }
                        }
                    }
                }
            }
            catch (Exception e)
            {
                logger.LogInfo("PunManager check failed: " + e.Message);
            }

            // Method 2: From SteamManager using reflection
            try
            {
                System.Type steamManagerType = System.Type.GetType("Steamworks.SteamManager, Assembly-CSharp");
                if (steamManagerType != null)
                {
                    object initialized = steamManagerType.GetProperty("Initialized").GetValue(null, null);
                    if ((bool)initialized)
                    {
                        System.Type steamUserType = System.Type.GetType("Steamworks.SteamUser, Assembly-CSharp");
                        object steamID = steamUserType.GetMethod("GetSteamID").Invoke(null, null);
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

            // Method 3: Find player controller - be more specific
            try
            {
                PlayerController[] players = UnityEngine.Object.FindObjectsOfType<PlayerController>();
                logger.LogInfo("Found " + players.Length + " PlayerControllers");

                foreach (PlayerController player in players)
                {
                    // Try common property/field names
                    string[] possibleNames = new string[] { "steamID", "steamId", "SteamID", "playerId", "PlayerID", "userID" };

                    foreach (string propName in possibleNames)
                    {
                        // Try property first
                        System.Reflection.PropertyInfo prop = player.GetType().GetProperty(propName,
                            System.Reflection.BindingFlags.Public |
                            System.Reflection.BindingFlags.NonPublic |
                            System.Reflection.BindingFlags.Instance);

                        if (prop != null)
                        {
                            object val = prop.GetValue(player, null);
                            if (val != null && val.GetType() == typeof(string))
                            {
                                string strVal = (string)val;
                                if (!string.IsNullOrEmpty(strVal) && strVal != "0")
                                {
                                    logger.LogInfo("Found Steam ID in property " + propName + ": " + strVal);
                                    return strVal;
                                }
                            }
                        }

                        // Try field
                        System.Reflection.FieldInfo field = player.GetType().GetField(propName,
                            System.Reflection.BindingFlags.Public |
                            System.Reflection.BindingFlags.NonPublic |
                            System.Reflection.BindingFlags.Instance);

                        if (field != null && field.FieldType == typeof(string))
                        {
                            object val = field.GetValue(player);
                            if (val != null)
                            {
                                string strVal = (string)val;
                                if (!string.IsNullOrEmpty(strVal) && strVal != "0")
                                {
                                    logger.LogInfo("Found Steam ID in field " + propName + ": " + strVal);
                                    return strVal;
                                }
                            }
                        }
                    }
                }
            }
            catch (Exception e)
            {
                logger.LogInfo("PlayerController method failed: " + e.Message);
            }

            logger.LogWarning("All methods failed to get Steam ID");
            return "";
        }

    }
}
