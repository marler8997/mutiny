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

        private void Awake()
        {
            logger = Logger;
            Logger.LogInfo("=== MARLER UPGRADE MOD LOADED ===");

            // Apply Harmony patches
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

        // Patch the DebugCommandHandler.Awake to register our commands after it initializes
        [HarmonyPatch(typeof(DebugCommandHandler))]
        [HarmonyPatch("Awake")]
        public class DebugCommandHandler_Awake_Patch
        {
            static void Postfix()
            {
                logger.LogInfo("DebugCommandHandler.Awake() called - registering our commands!");

                try
                {
                    RegisterUpgradeCommands();
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
                logger.LogInfo("Creating sprint command...");
                DebugCommandHandler.ChatCommand sprintCmd = new DebugCommandHandler.ChatCommand(
                    "sprint",
                    "Set sprint upgrade level. Usage: sprint <level>",
                    new Action<bool, string[]>(ExecuteSprintCommand),
                    null,
                    null,
                    false
                );

                logger.LogInfo("Registering sprint command...");
                DebugCommandHandler.instance.Register(sprintCmd);
                logger.LogInfo("Sprint command registered!");

                // Add more commands
                DebugCommandHandler.ChatCommand energyCmd = new DebugCommandHandler.ChatCommand(
                    "energy",
                    "Set energy upgrade level. Usage: energy <level>",
                    new Action<bool, string[]>(ExecuteEnergyCommand),
                    null,
                    null,
                    false
                );
                DebugCommandHandler.instance.Register(energyCmd);
                logger.LogInfo("Energy command registered!");

                DebugCommandHandler.ChatCommand healthCmd = new DebugCommandHandler.ChatCommand(
                    "health",
                    "Set health upgrade level. Usage: health <level>",
                    new Action<bool, string[]>(ExecuteHealthCommand),
                    null,
                    null,
                    false
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
            try
            {
                System.Type steamManagerType = System.Type.GetType("Steamworks.SteamManager");
                if (steamManagerType != null)
                {
                    object initialized = steamManagerType.GetProperty("Initialized").GetValue(null, null);
                    if ((bool)initialized)
                    {
                        System.Type steamUserType = System.Type.GetType("Steamworks.SteamUser");
                        object steamID = steamUserType.GetMethod("GetSteamID").Invoke(null, null);
                        return steamID.ToString();
                    }
                }
            }
            catch { }

            logger.LogWarning("Using empty Steam ID");
            return "";
        }
    }
}
