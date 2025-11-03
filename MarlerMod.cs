using BepInEx;
using UnityEngine;
using System;
using System.Collections.Generic;

namespace MarlerMod
{
    [BepInPlugin("com.marler.upgrademod", "Marler Upgrade Mod", "1.0.0")]
    public class Plugin : BaseUnityPlugin
    {
        private void Awake()
        {
            Logger.LogInfo("=== MARLER UPGRADE MOD LOADED ===");

            // Wait a frame for game systems to initialize
            StartCoroutine(RegisterCommandsDelayed());
        }

        private System.Collections.IEnumerator RegisterCommandsDelayed()
        {
            yield return new WaitForSeconds(1f);

            Logger.LogInfo("Registering custom commands...");

            try
            {
                RegisterUpgradeCommands();
                Logger.LogInfo("Commands registered successfully!");
            }
            catch (Exception e)
            {
                Logger.LogError("Failed to register commands: " + e.Message);
                Logger.LogError(e.StackTrace);
            }
        }

        private void RegisterUpgradeCommands()
        {
            // Sprint upgrade command
            DebugCommandHandler.ChatCommand sprintCmd = new DebugCommandHandler.ChatCommand();
            sprintCmd.Name = "sprint";
            sprintCmd.Description = "Set sprint upgrade level for all players. Usage: sprint <level>";
            sprintCmd.Execute = new Action<string[], Action<string>>(ExecuteSprintCommand);
            sprintCmd.IsDebug = false;
            DebugCommandHandler.instance.Register(sprintCmd);

            // Energy/Stamina upgrade command
            DebugCommandHandler.ChatCommand energyCmd = new DebugCommandHandler.ChatCommand();
            energyCmd.Name = "energy";
            energyCmd.Description = "Set energy upgrade level for all players. Usage: energy <level>";
            energyCmd.Execute = new Action<string[], Action<string>>(ExecuteEnergyCommand);
            energyCmd.IsDebug = false;
            DebugCommandHandler.instance.Register(energyCmd);

            // Health upgrade command
            DebugCommandHandler.ChatCommand healthCmd = new DebugCommandHandler.ChatCommand();
            healthCmd.Name = "health";
            healthCmd.Description = "Set health upgrade level for all players. Usage: health <level>";
            healthCmd.Execute = new Action<string[], Action<string>>(ExecuteHealthCommand);
            healthCmd.IsDebug = false;
            DebugCommandHandler.instance.Register(healthCmd);
        }

        private void ExecuteSprintCommand(string[] args, Action<string> response)
        {
            if (args.Length < 1)
            {
                response("Usage: sprint <level>");
                return;
            }

            int level;
            if (!int.TryParse(args[0], out level))
            {
                response("Invalid level. Must be a number.");
                return;
            }

            try
            {
                string steamID = GetLocalPlayerSteamID();
                int result = PunManager.instance.UpgradePlayerSprintSpeed(steamID, level);
                response(string.Format("Sprint upgraded to level {0} (result: {1})", level, result));
            }
            catch (Exception e)
            {
                response("Error: " + e.Message);
                Logger.LogError(e.StackTrace);
            }
        }

        private void ExecuteEnergyCommand(string[] args, Action<string> response)
        {
            if (args.Length < 1)
            {
                response("Usage: energy <level>");
                return;
            }

            int level;
            if (!int.TryParse(args[0], out level))
            {
                response("Invalid level. Must be a number.");
                return;
            }

            try
            {
                string steamID = GetLocalPlayerSteamID();
                int result = PunManager.instance.UpgradePlayerEnergy(steamID, level);
                response(string.Format("Energy upgraded to level {0} (result: {1})", level, result));
            }
            catch (Exception e)
            {
                response("Error: " + e.Message);
                Logger.LogError(e.StackTrace);
            }
        }

        private void ExecuteHealthCommand(string[] args, Action<string> response)
        {
            if (args.Length < 1)
            {
                response("Usage: health <level>");
                return;
            }

            int level;
            if (!int.TryParse(args[0], out level))
            {
                response("Invalid level. Must be a number.");
                return;
            }

            try
            {
                string steamID = GetLocalPlayerSteamID();
                int result = PunManager.instance.UpgradePlayerHealth(steamID, level);
                response(string.Format("Health upgraded to level {0} (result: {1})", level, result));
            }
            catch (Exception e)
            {
                response("Error: " + e.Message);
                Logger.LogError(e.StackTrace);
            }
        }

        private string GetLocalPlayerSteamID()
        {
            // Try to get local player's Steam ID
            // This might need adjustment based on how REPO stores player info
            if (Steamworks.SteamManager.Initialized)
            {
                return Steamworks.SteamUser.GetSteamID().ToString();
            }

            // Fallback - might need to find another way to get the ID
            Logger.LogWarning("Steam not initialized, using placeholder ID");
            return "0";
        }
    }
}
