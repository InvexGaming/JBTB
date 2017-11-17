#include <sourcemod>
#include <cstrike>
#include <sdktools>
#include <clientprefs>
#include <playtime>
#include <ctban>
#include <colors_csgo_v2>

#pragma semicolon 1
#pragma newdecls required

// Plugin Informaiton
#define VERSION "1.00"

public Plugin myinfo =
{
  name = "Jailbreak Team Balance",
  author = "Invex | Byte",
  description = "Powerful Team Balancer for Jailbreak.",
  version = VERSION,
  url = "http://www.invexgaming.com.au"
};

//ConVars
ConVar g_Cvar_Enabled = null;
ConVar g_Cvar_MinPlaytimeRequiredForCt = null;
ConVar g_Cvar_TeamChangePermittedDuration = null;

//Definitions
#define CHAT_TAG_PREFIX "[{lightred}JBTB{default}] "
#define MAX_MENU_OPTIONS 6
#define FALLBACK_RATIO 3.0
#define MAP_RATIO_NOTIFICATION_DELAY 30.0
#define GUARD_QUEUE_BUMP_NOTIFICATION_DISPLAY_TIME 7.0

//Enums
enum AddToGuardResult
{
  AddToGuardResult_Failure,
  AddToGuardResult_AddedToQueue,
  AddToGuardResult_MovedToCt
};

//Globals
ArrayList g_GuardQueue;
char g_RestrictedSound[32] = "buttons/button11.wav";
char g_SuccessSound[32] = "buttons/button17.wav";
bool g_IsTeamChangePermittedTime = false;
int g_GuardTime[MAXPLAYERS+1] = {-1};
bool g_IsFirstTeamSelection[MAXPLAYERS+1] = {false};
float g_CurrentMapRatio = FALLBACK_RATIO;

//Preference Cookies
Handle g_TeamPreferenceCookie = null; 

//Lateload
bool g_LateLoaded = false;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
  g_LateLoaded = late;
  return APLRes_Success;
}

// Plugin Start
public void OnPluginStart()
{
  //Translations
  LoadTranslations("common.phrases");
  LoadTranslations("jbtb.phrases");
  
  //Hooks
  HookUserMessage(GetUserMessageId("VGUIMenu"), UserMessage_VGUIMenu, true);
  HookEvent("round_prestart", Event_RoundPreStart, EventHookMode_Pre);
  HookEvent("round_start", Event_RoundStart, EventHookMode_Post);
  HookEvent("round_end", Event_RoundEnd, EventHookMode_Post);
  HookEvent("player_team", Event_PlayerTeamSwitch, EventHookMode_Post);
  AddCommandListener(Command_JoinTeam, "jointeam");
  
  //Flags
  CreateConVar("sm_jbtb_version", VERSION, "", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_CHEAT|FCVAR_DONTRECORD);
  
  //Cvars
  g_Cvar_Enabled = CreateConVar("sm_jbtb_enabled", "1", "Enables the jailbreak team balance system");
  g_Cvar_MinPlaytimeRequiredForCt = CreateConVar("sm_jbtb_minplaytimerequiredforct", "60", "The minimum amount of T playtime (in minutes) required to join CT");
  g_Cvar_TeamChangePermittedDuration = CreateConVar("sm_jbtb_teamchangepermittedduration", "10.0", "The duration of time (in seconds) which instant team changes can happen at the beginning of rounds.");
  
  //Create config file
  AutoExecConfig(true, "jbtb");
  
  //Commands
  RegConsoleCmd("sm_guard", Command_Guard, "Join the guard queue");
  RegConsoleCmd("sm_unguard", Command_Unguard, "Leave the guard queue");
  RegConsoleCmd("sm_prisoner", Command_Prisoner, "Move player to T team");
  RegConsoleCmd("sm_guardlist", Command_GuardList, "Display the guard queue as an ordered list");
  RegConsoleCmd("sm_pref", Command_SetTeamPreference, "Set your team preference");
  RegConsoleCmd("sm_ratio", Command_Ratio, "Print the current map ratio");
  RegAdminCmd("sm_removeguard", Command_RemoveGuard, ADMFLAG_GENERIC, "Remove a player from the guard queue");
  RegAdminCmd("sm_clearguard", Command_ClearGuard, ADMFLAG_GENERIC, "Remove all players from the guard queue");
  
  //Setup cookies
  g_TeamPreferenceCookie = RegClientCookie("JBTB_TeamPreference", "The preferred team to be placed on", CookieAccess_Private);
  
  //Late load
  if (g_LateLoaded) {
    for (int i = 1; i <= MaxClients; ++i) {
      if (IsClientInGame(i)) {
        //Set their start CT time
        if (GetClientTeam(i) == CS_TEAM_CT)
          g_GuardTime[i] = GetTime();
      }
    }
    
    g_LateLoaded = false;
  }
}

/*
 *
 * Events/Hooks
 *
 */
 
public Action UserMessage_VGUIMenu(UserMsg msg_id, Protobuf msg, const int[] players, int playersNum, bool reliable, bool init) 
{
  char buffermsg[64];
  PbReadString(msg, "name", buffermsg, sizeof(buffermsg));
  
  if (StrEqual(buffermsg, "team", true)) {
    int client = players[0];
    
    //If this team menu is the one on first join
    //Automatically set clients teams 1 second before mp_force_pick_time runs out
    //This will cancel out the CSGO default auto pick behavior
    if (g_IsFirstTeamSelection[client]) {
      g_IsFirstTeamSelection[client] = false;
      CreateTimer(FindConVar("mp_force_pick_time").FloatValue - 1.0, Timer_ForceAutoPick, client);
    }
  }
  
  return Plugin_Continue; 
}

public Action Event_RoundPreStart(Event event, const char[] name, bool dontBroadcast)
{
  if (!g_Cvar_Enabled.BoolValue)
    return Plugin_Continue;
  
  //Perform inital team changed here without respawning
  PerformAutoBalance(false);
  
  return Plugin_Continue;
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
  if (!g_Cvar_Enabled.BoolValue)
    return Plugin_Continue;
  
  //Set boolean to allow instant team changes
  g_IsTeamChangePermittedTime = true;
  CreateTimer(g_Cvar_TeamChangePermittedDuration.FloatValue, Timer_DisableTeamChangePermitted);
  
  //Create timer to keep autobalancing teams while team changes are permitted
  //This means that if during this period, we can constantly switch players around
  CreateTimer(0.5, Timer_PerformAutoBalance);
  
  return Plugin_Continue;
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
  if (!g_Cvar_Enabled.BoolValue)
    return Plugin_Continue;
  
  //If round ends early (i.e. within first 15 seconds of round), turn this off
  g_IsTeamChangePermittedTime = false;
  
  return Plugin_Continue;
}

//Player Team Switch (POST)
public Action Event_PlayerTeamSwitch(Event event, const char[] name, bool dontBroadcast)
{
  if (!g_Cvar_Enabled.BoolValue)
    return Plugin_Continue;
  
  int client = GetClientOfUserId(event.GetInt("userid"));
  int toTeam = event.GetInt("team");
  int fromTeam = event.GetInt("oldteam");
  
  //Ignore if team hasn't changed
  if (fromTeam == toTeam)
    return Plugin_Continue;
  
  //If leaving T team to a non T team
  if (fromTeam == CS_TEAM_T) {
    //Attempt to remove client from guard queue (or NOP if they weren't in it)
    if (RemoveClientFromGuardQueue(client))
      CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Removed Guard Left T");
  }
  
  //Update join time epoch if they moved to/from CT
  if (toTeam == CS_TEAM_CT)
    g_GuardTime[client] = GetTime();
  else if (fromTeam == CS_TEAM_CT)
    g_GuardTime[client] = -1;
  
  //If the last CT changed team past team change time, force a round draw
  if (!g_IsTeamChangePermittedTime) {
    if (fromTeam == CS_TEAM_CT && GetTeamClientCount(CS_TEAM_CT) == 1)
      CS_TerminateRound(FindConVar("mp_round_restart_delay").FloatValue, CSRoundEnd_Draw);
  }

  return Plugin_Continue;
}

// On map start
public void OnMapStart()
{
  if (!g_Cvar_Enabled.BoolValue)
    return;

  //Initilise guard queue for new map
  delete g_GuardQueue;
  g_GuardQueue = new ArrayList(1);

  //Set map specific ratio or defaults and call timer to print this to the server
  ReadMapRatioConfigFile();
  CreateTimer(MAP_RATIO_NOTIFICATION_DELAY, Timer_PrintMapRatio);
  
  return;
}

public void OnClientConnected(int client) 
{ 
  g_IsFirstTeamSelection[client] = true; 
}

//OnClientDisconnect
public void OnClientDisconnect(int client)
{
  if (!g_Cvar_Enabled.BoolValue)
    return;
    
  int clientTeam = GetClientTeam(client);
  
  //Attempt to remove client from guard queue (or NOP if they weren't in it)
  RemoveClientFromGuardQueue(client);
  
  //Update join time epoch if they disconnected from CT
  if (clientTeam == CS_TEAM_CT)
    g_GuardTime[client] = -1;
  
  //If the last CT disconnected past team change time, force a round draw
  if (!g_IsTeamChangePermittedTime) {
    if (clientTeam == CS_TEAM_CT && GetTeamClientCount(CS_TEAM_CT) == 1)
      CS_TerminateRound(FindConVar("mp_round_restart_delay").FloatValue, CSRoundEnd_Draw);
  }
  
  return;
}

public void OnConfigsExecuted()
{
  //Force mp_limitteams  to 0
  ConVar mp_limitteams = FindConVar("mp_limitteams");
  if (mp_limitteams != null)
    mp_limitteams.SetInt(0);
  
  //Force mp_autoteambalance to off
  ConVar mp_autoteambalance = FindConVar("mp_autoteambalance");
  if (mp_autoteambalance != null)
    mp_autoteambalance.SetBool(false);
}

public Action Command_JoinTeam(int client, const char[] command, int args)
{
  if (!g_Cvar_Enabled.BoolValue)
    return Plugin_Continue;
  
  if (args < 1)
		return Plugin_Handled;
  
  //Ensure client is valid
  if (!IsValidClient(client))
    return Plugin_Handled;
  
  char arg[4];
  GetCmdArg(1, arg, sizeof(arg));
  int fromTeam = GetClientTeam(client);
  int toTeam = StringToInt(arg);
  
  //Ignore requests to change to current team
  //unless to/from team is NONE as that means we are trying to autoselect
  if (toTeam == fromTeam && toTeam != CS_TEAM_NONE && fromTeam != CS_TEAM_NONE)
    return Plugin_Handled;
  
  if (toTeam == CS_TEAM_CT) {
    //Attempt to add them to the guards team
    AddToGuardResult status = AttemptAddClientToGuards(client);
    
    //If they were added to the queue, place them on T side
    if (status == AddToGuardResult_AddedToQueue) {
      ClientCommand(client, "play %s", g_SuccessSound);
      toTeam = CS_TEAM_T;
    }
    //If they were moved to CT, nothing more to do
    else if (status == AddToGuardResult_MovedToCt) {
      ClientCommand(client, "play %s", g_SuccessSound);
      return Plugin_Handled;
    }
    //If this failed, re-display team select menu so they can pick another option
    else if (status == AddToGuardResult_Failure) {
      ClientCommand(client, "play %s", g_RestrictedSound);
      return Plugin_Handled;
    }
  }
  
  //If they pick auto select, make them move to T by default
  if (toTeam == CS_TEAM_NONE)
    toTeam = CS_TEAM_T;
  
  //Perform an instant team change
  //As we return Plugin_Handled at all times, this can be done safely here without a delay
  ChangeClientTeam(client, toTeam);
  
  return Plugin_Handled;
}

/*
 *
 * Forwards
 *
 */

public void CTBan_OnClientBan(int client, int admin, int minutes, const char[] reason)
{
  if (RemoveClientFromGuardQueue(client))
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Removed Guard CT Ban");
}
 
//Add T side client to guard queue
public Action Command_Guard(int client, int args)
{
  if (!g_Cvar_Enabled.BoolValue)
    return Plugin_Handled;
  
  //Ensure client is valid
  if (!IsValidClient(client))
    return Plugin_Handled;
  
  //Client should be on T side to issue this command
  if (GetClientTeam(client) != CS_TEAM_T) {
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Guard Command Not T");
    return Plugin_Handled;
  }
  
  //Attempt to add them to the guard queue
  AttemptAddClientToGuards(client);
  
  return Plugin_Handled;
}

//Remove T side client from guard queue
public Action Command_Unguard(int client, int args)
{
  if (!g_Cvar_Enabled.BoolValue)
    return Plugin_Handled;
  
  //Ensure client is valid
  if (!IsValidClient(client))
    return Plugin_Handled;
    
  //Client should be on T side to issue this command
  if (GetClientTeam(client) != CS_TEAM_T) {
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Unguard Command Not T");
    return Plugin_Handled;
  }
  
  //Remove client from guard queue
  if (RemoveClientFromGuardQueue(client))
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Removed Guard Unguard");
  else
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Unguard Not In Guard Queue");
  
  return Plugin_Handled;
}

//Moves player to T team
public Action Command_Prisoner(int client, int args)
{
  if (!g_Cvar_Enabled.BoolValue)
    return Plugin_Handled;
  
  //Ensure client is valid
  if (!IsValidClient(client))
    return Plugin_Handled;
  
  //Client should be on CT/Spec side to issue this command
  if (GetClientTeam(client) != CS_TEAM_CT && GetClientTeam(client) != CS_TEAM_SPECTATOR) {
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Prisoner Command On T");
    return Plugin_Handled;
  }
  
  //Delegate to jointeam
  FakeClientCommand(client, "jointeam %d", CS_TEAM_T);
  
  return Plugin_Handled;
}

//Display the guard queue as an ordered list
public Action Command_GuardList(int client, int args)
{
  if (!g_Cvar_Enabled.BoolValue)
    return Plugin_Handled;
  
  //Ensure client is valid
  if (!IsValidClient(client))
    return Plugin_Handled;
    
  //Create a menu
  Menu guardListMenu = new Menu(GuardListMenuHandler, MenuAction_Select|MenuAction_Cancel|MenuAction_End|MenuAction_DisplayItem);
  
  //Need dummy items or else menu wont show correct pagination
  int numPagesNeeded = RoundToCeil(g_GuardQueue.Length / 10.0);
  
  //There should be 1 page minimum
  if (numPagesNeeded == 0)
    numPagesNeeded = 1;
  
  for (int i = 0; i < MAX_MENU_OPTIONS * numPagesNeeded; ++i)
    guardListMenu.AddItem("", "", ITEMDRAW_NOTEXT);
  
  guardListMenu.Display(client, MENU_TIME_FOREVER);
  
  return Plugin_Handled;
}

//Uses cookies to set a team preference
public Action Command_SetTeamPreference(int client, int args)
{
  if (!g_Cvar_Enabled.BoolValue)
    return Plugin_Handled;
  
  //Ensure client is valid
  if (!IsValidClient(client))
    return Plugin_Handled;
  
  //If no arguments provided, print current preference
  if (args < 1) {
    int teamPref = GetClientTeamPreference(client);
    
    if (teamPref == -1) {
      CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Error Retrieve Preference Cookie");
      return Plugin_Handled;
    }
    
    if (teamPref == CS_TEAM_CT)
      CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Current Team Preference", "{lightblue}GUARD{default}");
    else if (teamPref == CS_TEAM_T)
      CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Current Team Preference", "{yellow}PRISONERS{default}");
    
    return Plugin_Handled;
  }
  
  //Otherwise, set their preference
  char buffer[16];
  GetCmdArg(1, buffer, sizeof(buffer));
  
  if (StrEqual(buffer, "CT", false) || StrEqual(buffer, "GUARD", false)) {
    SetClientTeamPreference(client, CS_TEAM_CT);
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Current Team Preference", "{lightblue}GUARD{default}");
  }
  else if (StrEqual(buffer, "T", false) || StrEqual(buffer, "PRISONER", false)) {
    SetClientTeamPreference(client, CS_TEAM_T);
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Current Team Preference", "{yellow}PRISONERS{default}");
  }
  else {
    char cmd[32];
    GetCmdArg(0, cmd, sizeof(cmd));
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Incorrect Command Usage", cmd, "<GUARD|CT|PRISONER|T>");
  }
  
  return Plugin_Handled;
}

//Print current map ratio to client
public Action Command_Ratio(int client, int args)
{
  if (!g_Cvar_Enabled.BoolValue)
    return Plugin_Handled;
    
  //Ensure client is valid
  if (!IsValidClient(client))
    return Plugin_Handled;
  
  CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Map Ratio Notification", g_CurrentMapRatio);
  
  return Plugin_Handled;
}

//Remove a player from the guard queue
public Action Command_RemoveGuard(int client, int args)
{
  if (!g_Cvar_Enabled.BoolValue)
    return Plugin_Handled;
    
  //Ensure client is valid
  if (!IsValidClient(client))
    return Plugin_Handled;
  
  //Get target users
  if (args < 1) {
    char cmd[32];
    GetCmdArg(0, cmd, sizeof(cmd));
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Incorrect Command Usage", cmd, "<target>");
    return Plugin_Handled;
  }
  
  char target[64];
  GetCmdArg(1, target, sizeof(target));
  
  char target_name[MAX_TARGET_LENGTH];
  int target_list[MAXPLAYERS], target_count;
  bool tn_is_ml;
  
  if ((target_count = ProcessTargetString(
      target,
      client,
      target_list,
      MAXPLAYERS,
      0,
      target_name,
      sizeof(target_name),
      tn_is_ml)) <= 0)
  {
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "RemoveGuard No Targets");
    return Plugin_Handled;
	}
  
  bool targetProcessed = false;
  
  for (int i = 0; i < target_count; ++i) {
    if (RemoveClientFromGuardQueue(target_list[i])) {
      CPrintToChatAll("%s%t", CHAT_TAG_PREFIX, "RemoveGuard Admin", target_list[i], client);
      targetProcessed = true;
    }
  }
  
  //Print message if targets found but no body was removed
  if (!targetProcessed)
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "RemoveGuard No Targets");
  
  return Plugin_Handled;
}

//Remove all players from the guard queue
public Action Command_ClearGuard(int client, int args)
{
  if (!g_Cvar_Enabled.BoolValue)
    return Plugin_Handled;
  
  //Ensure client is valid
  if (!IsValidClient(client))
    return Plugin_Handled;
  
  //Clear guard queue
  g_GuardQueue.Clear();
  
  CPrintToChatAll("%s%t", CHAT_TAG_PREFIX, "ClearGuard Admin", client);
  
  return Plugin_Handled;
}

/*
 *
 * Timers
 *
 */

//Disable team change permitted boolean
public Action Timer_DisableTeamChangePermitted(Handle timer)
{
  g_IsTeamChangePermittedTime = false;
}

//Perform Auto Balance
public Action Timer_PerformAutoBalance(Handle timer)
{
  if (g_IsTeamChangePermittedTime) {
    PerformAutoBalance(true);
    CreateTimer(1.0, Timer_PerformAutoBalance);
  }
}

//Force a team on a client overriding default CSGO Auto Pick behaviour
public Action Timer_ForceAutoPick(Handle Timer, int client) 
{ 
  if (IsClientInGame(client) && GetClientTeam(client) == CS_TEAM_NONE) {
    ChangeClientTeam(client, CS_TEAM_SPECTATOR);
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Force Auto Pick");
  }
}

//Display bump notification once per second
public Action Timer_ShowQueueBumpNotification(Handle timer, DataPack pack)
{
  pack.Reset();
  int client = pack.ReadCell();
  int position = pack.ReadCell();
  float secondsLeft = pack.ReadFloat();
  
  if (IsValidClient(client) && secondsLeft > 0) {
    PrintCenterText(client, "%t", "Guard Bump Notification", position);
    pack.Reset(true);
    pack.WriteCell(client);
    pack.WriteCell(position);
    pack.WriteFloat(--secondsLeft);
    CreateTimer(1.0, Timer_ShowQueueBumpNotification, pack);
  } else {
    delete pack;
  }
  
  return Plugin_Handled;
}

//Print out the map specific ratio
public Action Timer_PrintMapRatio(Handle timer)
{
  CPrintToChatAll("%s%t", CHAT_TAG_PREFIX, "Map Ratio Notification", g_CurrentMapRatio);
}

/*
 *
 * Menu's and Menu Handlers
 *
 */

public int GuardListMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
  switch (action)
  {
    case MenuAction_DisplayItem:
    {
      //Kind of hacky, reset the menu title only if its first item of each page
      //This is so we only 'refresh' the title once per menu page
      if (param2 % MAX_MENU_OPTIONS == 0) {
        char titleString[1024];
        Format(titleString, sizeof(titleString), "Guard List:\n ");
        
        //Handle empty list case
        if(g_GuardQueue.Length == 0) {
          Format(titleString, sizeof(titleString), "%s\n  Empty", titleString);
        }
        else {
          //Show 10 entries per page otherwise
          int min = (param2 / MAX_MENU_OPTIONS) * 10;
          int max = min + 10;
          if (max > g_GuardQueue.Length)
            max = g_GuardQueue.Length;
          
          for (int i = min; i < max; ++i) {
            int client = g_GuardQueue.Get(i);
            Format(titleString, sizeof(titleString), "%s\n%d. %N (#%i) [PT: %d]", titleString, i+1, client, GetClientUserId(client), GetClientPlayTime(client, CS_TEAM_CT));
          }
        }
        
        menu.SetTitle(titleString);
      }
    }
    
    case MenuAction_End:
    {
      delete menu;
    }
  }
}

/*
 *
 * Helper Functions / Other
 *
 */
 
//Standard valid client checking
bool IsValidClient(int client)
{
  if (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client))
    return true;
    
  return false;
}

//Check if players should be swapped from 'fromTeam' to 'toTeam'
//Based on team ratios
bool ShouldAutoBalance(int fromTeam, int toTeam)
{
  if (toTeam == CS_TEAM_NONE || toTeam == CS_TEAM_SPECTATOR)
    return false;
  
  //Get number of T and CT players
  int numCt = GetTeamClientCount(CS_TEAM_CT);
  int numT = GetTeamClientCount(CS_TEAM_T);
  
  if (toTeam == CS_TEAM_T) {
    
    if (fromTeam == CS_TEAM_CT) {
      float curRatio = CalculateTeamRatio(numT, numCt);
      
      //If current ratio is fine, no need to move anyone from CT to T
      if (curRatio >= g_CurrentMapRatio)
        return false;
      else
        return true;
    }
    
    return false;
  }
  else if (toTeam == CS_TEAM_CT) {
    //Check resultant ratio if player was moved to the CT team
    if (fromTeam == CS_TEAM_T)
      --numT; //1 less player on T if they are from T
    
    ++numCt; //1 extra player on CT
    
    float ratio = CalculateTeamRatio(numT, numCt);
    
    //If resultant ratio is still at least X T's per 1 CT
    //Then the change doesn't break the ratio and should happen
    if (ratio >= g_CurrentMapRatio)
      return true;
    else
      return false;
  }
  
  return false;
}

//Move over as many clients over from T to CT as long as long as future ratio is satisfied
//Move over excess guards from CT to T as long as current ratio is not satisfied
void PerformAutoBalance(bool respawn)
{
  //Don't need to autobalance if there is only 1 player
  if (GetTeamClientCount(CS_TEAM_T) + GetTeamClientCount(CS_TEAM_CT) <= 1) {
    return;
  }
  
  //T -> CT
  while (ShouldAutoBalance(CS_TEAM_T, CS_TEAM_CT)) {
    int nextClient = -1;
    
    if (g_GuardQueue.Length != 0) {
      //Get head of queue and remove them from the queue
      nextClient = g_GuardQueue.Get(0);
      RemoveClientFromGuardQueue(nextClient);
    }
    else {
      //Otherwise, we have to pick a player from all T's
      
      //First try to pick a random eligble T player considering preferences
      nextClient = GetRandomPlayerFromT(true);
      
      //Otherwise, we have to pick a random eligble T player ignoring preference
      if (nextClient == -1)
        nextClient = GetRandomPlayerFromT(false);
    }
    
    //If no valid client to move break as we can't move anybody
    if (nextClient == -1)
      break;
    
    //Switch this user to the CT team
    ChangeClientTeam(nextClient, CS_TEAM_CT);
    
    if (respawn && !IsPlayerAlive(nextClient)) {
      //Respawn them if they are dead
      CS_RespawnPlayer(nextClient);
    }
    
    CPrintToChat(nextClient, "%s%t", CHAT_TAG_PREFIX, "Moved To Guard");
  }
  
  //CT -> T
  while (ShouldAutoBalance(CS_TEAM_CT, CS_TEAM_T)) {
    int nextClient = -1;
    int mostGuardTime = -1;
    
    //Pick the player who has been on CT side the longest
    for (int i = 1; i <= MaxClients; ++i) {
      if (IsClientInGame(i) && GetClientTeam(i) == CS_TEAM_CT) {
        int guardTime = GetTime() - g_GuardTime[i];
        if (guardTime >  mostGuardTime) {
          mostGuardTime = guardTime;
          nextClient = i;
        }
      }
    }
    
    //If no valid client to move break as we can't move anybody
    if (nextClient == -1)
      break;
    
    //Switch this user to the T team
    ChangeClientTeam(nextClient, CS_TEAM_T);
    
    if (respawn && !IsPlayerAlive(nextClient)) {
      //Respawn them if they are dead
      CS_RespawnPlayer(nextClient);
    }
    
    CPrintToChat(nextClient, "%s%t", CHAT_TAG_PREFIX, "Moved To Prisoner");
  }
}

//Attempts to add a client to the guard team or the guard queue otherwise
//Assumes that if a player is added to the guard queue they are on the T team or will be moved to it directly afterwards
AddToGuardResult AttemptAddClientToGuards(int client)
{
  //Check to see if client has enough CT playtime to join guards or guard queue
  int tPlayTime;
  if (!IsClientPtEnoughToJoinCt(client, tPlayTime)) {
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Cant Join Guard PlayTime", tPlayTime, g_Cvar_MinPlaytimeRequiredForCt.IntValue);
    return AddToGuardResult_Failure;
  }
  
  //Check to see if client is CT banned
  if (CTBan_IsClientBanned(client)) {
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Cant Join Guard CT Ban");
    return AddToGuardResult_Failure;
  }
  
  //Special Case: 1 player in server that is joining CT
  //Don't need to add to guard queue if there is only 1 player
  //Simply move them instantly to CT
  int numCt = GetTeamClientCount(CS_TEAM_CT) + 1;
  int numT = GetTeamClientCount(CS_TEAM_T);
  
  if (numCt + numT <= 1) {
    ChangeClientTeam(client, CS_TEAM_CT);
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Moved To Guard Instant");
    return AddToGuardResult_MovedToCt;
  }
  
  //If the guard queue is empty
  //See if we can bypass the queue system and move this client over
  if (g_GuardQueue.Length == 0) {
    if (ShouldAutoBalance(GetClientTeam(client), CS_TEAM_CT)) {
      //We have a position available on CT
      ChangeClientTeam(client, CS_TEAM_CT);
      CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Moved To Guard Instant");
      return AddToGuardResult_MovedToCt;
    }
  }
  
  //Check if already in queue
  int queuePosition = g_GuardQueue.FindValue(client);
  if (queuePosition != -1) {
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Already In Guard Queue", queuePosition + 1);
    return AddToGuardResult_Failure;
  }
  
  //Add client to queue
  int newQueuePosition = g_GuardQueue.Push(client);
  CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Added To Guard Queue", newQueuePosition + 1);
  
  return AddToGuardResult_AddedToQueue;
}

//Attempts to remove a client from the guard queue if they are in it
//Returns true if client removed from queue, false otherwise
bool RemoveClientFromGuardQueue(int client)
{
  if (!IsValidClient(client))
    return false;

  int index = g_GuardQueue.FindValue(client);
  if (index == -1) {
    return false;
  }
  else {
    g_GuardQueue.Erase(index);
    DisplayGuardQueueBumpNotifications(index);
    return true;
  }
}

//Displays a notification to all guards that now sit at the provided index or higher
//Letting them know they moved up a position in the guard queue
void DisplayGuardQueueBumpNotifications(int index)
{
  for (int i = index; i < g_GuardQueue.Length; ++i) {
    //Show notification
    DataPack pack = CreateDataPack();
    pack.WriteCell(g_GuardQueue.Get(i)); //client
    pack.WriteCell(i + 1); //new position in queue
    pack.WriteFloat(GUARD_QUEUE_BUMP_NOTIFICATION_DISPLAY_TIME); //number of second to display
    CreateTimer(0.0, Timer_ShowQueueBumpNotification, pack);
  }
}

//Calculate the CT/T ratio
//It returns the number of T's that exist per CT
//So a value of 4.5 means 4.5 T's exist for every CT
float CalculateTeamRatio(int numT, int numCt)
{
  if (numCt == 0 || numCt == 1)
    return 999.9;
    
  return float(numT) / float(numCt);
}

//Return clients team preference or -1 if issues reading from cookie/default cookie
int GetClientTeamPreference(int client)
{
  if (AreClientCookiesCached(client)) {
    char buffer[2];
    GetClientCookie(client, g_TeamPreferenceCookie, buffer, sizeof(buffer));
    if (strlen(buffer) == 0) { //set default for empty cookie
      SetClientTeamPreference(client, CS_TEAM_CT);
      return CS_TEAM_CT;
    }
    else
      return (StringToInt(buffer) == 0) ? -1 : StringToInt(buffer);
  }
  
  return -1;
}

//Set clients team preference
bool SetClientTeamPreference(int client, int team)
{
  if (AreClientCookiesCached(client)) {
    char buffer[2];
    IntToString(team, buffer, sizeof(buffer));
    SetClientCookie(client, g_TeamPreferenceCookie, buffer);
    return true;
  }
  
  return false;
}

//Selects a random eligble client from T side to be move to CT
//Ensures: They are in game, on T side, have enough T PT, is not CT banned and optionally their team preference
int GetRandomPlayerFromT(bool considerPreference)
{
  int clients[MAXPLAYERS+1];
  int clientCount = 0;
  for (int i = 1; i <= MaxClients; i++) {
    if (IsClientInGame(i) && (GetClientTeam(i) == CS_TEAM_T) && IsClientPtEnoughToJoinCt(i) && !CTBan_IsClientBanned(i)) {
      if (considerPreference && (GetClientTeamPreference(i) == CS_TEAM_T))
        continue;
      
      clients[clientCount++] = i;
    }
  }
  return (clientCount == 0) ? -1 : clients[GetRandomInt(0, clientCount - 1)];
}

//Check if player has enough T side playtime to join CT
//Returns true if they do, false otherwise. Also returns playtime via reference
bool IsClientPtEnoughToJoinCt(int client, int &tPlayTime = 0)
{
  //Fake clients have enough playtime by default
  if (IsFakeClient(client))
    return true;
  
  tPlayTime = GetClientPlayTime(client, CS_TEAM_T);
  if (tPlayTime == -1)
    return false;
  else if (tPlayTime < g_Cvar_MinPlaytimeRequiredForCt.IntValue)
    return false;
  else
    return true;
}

//Read Map Ratio Config File to set the ratio for the current map
void ReadMapRatioConfigFile()
{
  char path[PLATFORM_MAX_PATH];
  Format(path, sizeof(path), "configs/jbtb_mapratios.cfg");
  BuildPath(Path_SM, path, sizeof(path), path);
  
  if (!FileExists(path))
    SetFailState("Config file 'jbtb_mapratios.cfg' was not found");
  
  KeyValues kv = new KeyValues("MapRatios");
  if (!kv.ImportFromFile(path))
    SetFailState("Error importing config file 'jbtb_mapratios.cfg' in KeyValue format");

  char currentMapName[255];
  GetCurrentMap(currentMapName, sizeof(currentMapName));
  
  if(kv.GotoFirstSubKey(true)) {
    do {
      //Get map name
      char kvMapName[255];
      kv.GetSectionName(kvMapName, sizeof(kvMapName));
      
      //Get Ratio
      float kvRatio = kv.GetFloat("ratio", FALLBACK_RATIO);
      
      //Set ratio if this is default key
      if (StrEqual(kvMapName, "Default", false)) {
        g_CurrentMapRatio = kvRatio;
      }
      //Otherwise, if its the map key, set and break out of loop
      else if (StrEqual(kvMapName, currentMapName, false)) {
        g_CurrentMapRatio = kvRatio;
        break;
      }
    }
    while(kv.GotoNextKey(true));
    
    kv.GoBack();
  }
  
  delete kv;
}
