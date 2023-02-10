#include <sourcemod>

#include <sdkhooks>
#include <sdktools>

#include <tf2_stocks>

#include <stocksoup/memory>
#include <stocksoup/tf/hud_notify>

#pragma newdecls required
#pragma semicolon 1

public Plugin myinfo =
{
	name         =  "[TF2] AllClassReviveMarker",
	author       =  "Zabaniya001",
	description  =  "[TF2] Allows every class to revive players from revive markers.",
	version      =  "1.0.0",
	url          =  "https://github.com/Zabaniya001/AllClassReviveMarker"
};

ConVar g_convar_distance;
ConVar g_convar_reviverate;

int g_CTFReviveMarker_pReviver;
int g_CTFReviveMarker_bOwnerPromptedToRevive;

Handle g_SDKCall_CTFReviveMarkerAddMarkerHealth;

public void OnPluginStart()
{
	g_convar_distance   =  CreateConVar("sm_allclassrevivemarker_revivedistance", "120.0", "Dictates the maximum distance between the client and the revive marker while reviving");
	g_convar_reviverate =  CreateConVar("sm_allclassrevivemarker_reviverate", "0.2", "Dictates the amount of healing done every frame ( this is close to medic's revive rate )");

	int CTFReviveMarker_nRevives = FindSendPropInfo("CTFReviveMarker", "m_nRevives");

	if(CTFReviveMarker_nRevives == -1)
		SetFailState("CTFReviveMarker::m_nRevives hasn't been found.");
	
	g_CTFReviveMarker_pReviver = CTFReviveMarker_nRevives - 0x4;
	
	g_CTFReviveMarker_bOwnerPromptedToRevive = CTFReviveMarker_nRevives + 0x4 + 0x4; // m_nRevives -> m_flHealAccumulator -> m_bOwnerPromptedToRevive ( or entity address + 0x4D4 )

	if(g_CTFReviveMarker_bOwnerPromptedToRevive == -1)
		SetFailState("CTFReviveMarker::m_bOwnerPromptedToRevive hasn't been found. Address has most likely changed.");
	
	GameData gamedata = new GameData("tf2.allclassrevivemarker");

	// CTFReviveMarker::AddMarkerHealth()
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Signature, "CTFReviveMarker::AddMarkerHealth()");
	PrepSDKCall_AddParameter(SDKType_Float, SDKPass_Plain);
	g_SDKCall_CTFReviveMarkerAddMarkerHealth = EndPrepSDKCall();

	if(!g_SDKCall_CTFReviveMarkerAddMarkerHealth)
		SetFailState("Failed to setup SDKCall for CTFReviveMarker::AddMarkerHealth()");

	delete gamedata;

	// Late-load
	for(int client = 1; client <= MaxClients; client++)
	{
		if(!IsClientInGame(client))
			continue;

		OnClientPutInServer(client);
	}

	return;
}

public void OnMapStart()
{
	PrecacheScriptSound("WeaponMedigun.HealingTarget");
	PrecacheSound("weapons/medigun_heal.wav", true);

	return;
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamagePost, OnTakeDamagePost);
	SDKHook(client, SDKHook_PreThink, OnClientPreThinkPost);

	return;
}

void OnTakeDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype)
{
	if(GetClientHealth(victim) > 0.0)
		return;
	
	SpawnReviveMarker(victim);

	return;
}

void OnClientPreThinkPost(int client)
{
	// Medic can already revive teammates through its medigun.
	if(TF2_GetPlayerClass(client) == TFClass_Medic)
		return;
	
	static int revive_marker_list[36] = {INVALID_ENT_REFERENCE, ...};
	static int client_beam[36] = {INVALID_ENT_REFERENCE, ...};

	int buttons = GetClientButtons(client);

	if(!(buttons & IN_RELOAD))
	{
		int released_buttons = GetEntProp(client, Prop_Data, "m_afButtonReleased");

		if(released_buttons & IN_RELOAD)
		{
			int beam = EntRefToEntIndex(client_beam[client]);

			if(beam == INVALID_ENT_REFERENCE)
				return;
			
			DisableMedigunLikeEffects(client, beam);			
		}
			
		return;
	}
	
	/* I don't like this approach whatsoever, but I need to run some things below only once and it's the only one that's slightly less invasive. */

	int revive_marker = EntRefToEntIndex(revive_marker_list[client]);

	if(revive_marker == INVALID_ENT_REFERENCE)
	{	
		revive_marker = WhichReviveMarkerIsClientLookingAt(client, .max_distance = g_convar_distance.FloatValue);

		// INVALID_ENT_REFERENCE means that the client isn't looking at one
		if(revive_marker == -1)
			return;
		
		// We can't revive another team's revive marker
		if(TF2_GetClientTeam(client) != view_as<TFTeam>(GetEntProp(revive_marker, Prop_Send, "m_iTeamNum")))
			return;

		revive_marker_list[client] = EntIndexToEntRef(revive_marker);
	}

	if(EntRefToEntIndex(client_beam[client]) == INVALID_ENT_REFERENCE)
	{
		/* We manually have to add visual and audio cues to mimic reviving. */

		// Medigun beam effect so it's more clear who we are reviving.
		client_beam[client] = EntIndexToEntRef(TF2_SpawnAndConnectMedigunBeam(client, revive_marker));

		// Audio so you can hear the revival happening.
		EmitSoundToAll(")weapons/medigun_heal.wav", client);
	}

	int revive_marker_owner = GetEntPropEnt(revive_marker, Prop_Send, "m_hOwner");
	
	bool result = StartRevivingPlayer(client, revive_marker_owner, revive_marker);

	if(result)
	{
		// Show the health bar
		int health     =  GetEntProp(revive_marker, Prop_Data, "m_iHealth");
		int max_health =  GetEntProp(revive_marker, Prop_Data, "m_iMaxHealth");
		TF2_ShowHudNotificationToClient(client, "", TF2_GetClientTeam(client), "%i / %i", health, max_health); // Unfortunately "health_icon" is not centered.

		// If m_iHealth is >= m_iMaxHealth, it means that the player will be soon revived so we have to remove the medigun-like effects.
		if(health >= max_health)
		{
			int beam = EntRefToEntIndex(client_beam[client]);

			if(beam == INVALID_ENT_REFERENCE)
				return;
			
			DisableMedigunLikeEffects(client, beam);
		}
	}
	else
	{
		revive_marker_list[client] = INVALID_ENT_REFERENCE;

		int beam = EntRefToEntIndex(client_beam[client]);

		if(beam == INVALID_ENT_REFERENCE)
			return;
		
		DisableMedigunLikeEffects(client, beam);
	}

	return;
}

int WhichReviveMarkerIsClientLookingAt(int client, float max_distance)
{
	float client_position[3], ang_eyes[3];
	GetClientEyePosition(client, client_position);
	GetClientEyeAngles(client, ang_eyes);
	
	Handle trace = TR_TraceRayFilterEx(client_position, ang_eyes, MASK_SHOT, RayType_Infinite, TraceEntityFilterPlayer);

	if(!TR_DidHit(trace))
		return -1;

	int target = TR_GetEntityIndex(trace);

	float target_position[3];
	TR_GetEndPosition(target_position, trace);

	delete trace;

	float distance = GetVectorDistance(client_position, target_position);

	if(distance > max_distance)
		return -1;
	
	char classname[64];
	GetEntityClassname(target, classname, sizeof(classname));
	
	return StrEqual(classname, "entity_revive_marker") ? target : -1;
}

bool TraceEntityFilterPlayer(int entity, int contentsMask)
{
	return entity > MaxClients || !entity;
}

bool StartRevivingPlayer(int reviver, int target, int revive_marker)
{
	float reviver_pos[3], revive_marker_pos[3];

	GetEntPropVector(reviver, Prop_Send, "m_vecOrigin", reviver_pos);
	GetEntPropVector(revive_marker, Prop_Send, "m_vecOrigin", revive_marker_pos);

	// Since we are already "hooked" to the revive marker, we don't require the client to look at the revive marker the whole time.
	// It'll keep reviving as long as they stay within the range.
	if(GetVectorDistance(reviver_pos, revive_marker_pos) > g_convar_distance.FloatValue)
		return false;
	
	// CTFReviveMarker has a pReviver that indicates who is reviving the player.
	// It's used to award points and decide where to spawn once the player gets
	// successfully revived.
	SetEntData(revive_marker, g_CTFReviveMarker_pReviver, GetEntityAddress(reviver));

	// Whoever we are reviving has to spectate us.
	SetObserverToReviver(target, reviver);

	// CTFReviveMarker::PromptOwner gets called only in CWeaponMedigun::HealTargetThink, so we have to call it outselves
	// to properly mimic the revive.
	PromptOwner(target, revive_marker);

	// This calls CTFReviveMarker::AddMarkerHealth, which takes care most of the stuff regarding reviving.
	AddMarkerHealth(revive_marker, g_convar_reviverate.FloatValue);

	return true;
}

void SetObserverToReviver(int client, int target)
{
	if(GetEntProp(client, Prop_Send, "m_iObserverMode") <= 2)
		return;
	
	if(GetEntProp(client, Prop_Send, "m_hObserverTarget") == target)
		return;
	
	SetEntProp(client, Prop_Send, "m_hObserverTarget", target);

	return;
}

// Recreation of CTFReviveMarker::PromptOwner
void PromptOwner(int client, int revive_marker)
{
	if(HasOwnerBeenPrompted(revive_marker))
		return;
	
	Event event = CreateEvent("revive_player_notify");

	event.SetInt("entindex", client);
	event.SetInt("marker_entindex", revive_marker);

	event.Fire();

	SetOwnerHasBeenPrompted(revive_marker, true);

	return;
}

void HasOwnerBeenPrompted(int revive_marker)
{
	LoadFromAddress(GetEntityAddress(revive_marker) + view_as<Address>(g_CTFReviveMarker_bOwnerPromptedToRevive), NumberType_Int32);

	return;
}

void SetOwnerHasBeenPrompted(int revive_marker, bool value)
{
	StoreToAddress(GetEntityAddress(revive_marker) + view_as<Address>(g_CTFReviveMarker_bOwnerPromptedToRevive), value, NumberType_Int32);

	return;
}

void AddMarkerHealth(int revive_marker, float amount)
{
	SDKCall(g_SDKCall_CTFReviveMarkerAddMarkerHealth, revive_marker, amount);

	return;
}

int SpawnReviveMarker(int client)
{
	int revive_marker = CreateEntityByName("entity_revive_marker");

	if(revive_marker == -1)
		return -1;
	
	int client_team = GetClientTeam(client);
	int client_class = view_as<int>(TF2_GetPlayerClass(client));

	SetEntPropEnt(revive_marker, Prop_Send, "m_hOwnerEntity", client);
	SetEntPropEnt(revive_marker, Prop_Send, "m_hOwner", client);
	SetEntProp(revive_marker, Prop_Send, "m_iTeamNum", client_team);
	SetEntProp(revive_marker, Prop_Data, "m_iInitialTeamNum", client_team);
	SetEntDataEnt2(client, FindSendPropInfo("CTFPlayer", "m_nForcedSkin") + 4, revive_marker);
	SetEntProp(revive_marker, Prop_Send, "m_nBody", client_class - 1);

	// The revive marker has only the red team variation, so we have to manually color it.
	if(client_team == view_as<int>(TFTeam_Blue))
		SetEntityRenderColor(revive_marker, 0, 0, 255);

	DispatchSpawn(revive_marker);

	// For some reason, the revive marker will block projectiles like rockets, arrows and etc... but not hitscan projectiles
	// if the revive marker is not from your same team. Otherwise, it works as intended ( aka everything goes through them ).
	// Changing m_usSolidFlags from FSOLID_TRIGGER ( 8 ) to FSOLID_CUSTOMRAYTEST ( 1 ) fixes it.
	SetEntProp(revive_marker, Prop_Send, "m_usSolidFlags", 1);

	float client_position[3];
	GetEntPropVector(client, Prop_Send, "m_vecOrigin", client_position);
	TeleportEntity(revive_marker, client_position, NULL_VECTOR, NULL_VECTOR);
	
	return revive_marker;
}

// Borrwed some parts from 4242.
int TF2_SpawnAndConnectMedigunBeam(int healer, int target)
{
	int particle = CreateEntityByName("info_particle_system");
	DispatchKeyValue(particle, "effect_name", TF2_GetClientTeam(healer) == TFTeam_Red ? "medicgun_beam_red_targeted" : "medicgun_beam_blue_targeted");
	DispatchSpawn(particle);
	
	float vecOrigin[3];
	GetEntPropVector(healer, Prop_Send, "m_vecOrigin", vecOrigin);
	TeleportEntity(particle, vecOrigin, NULL_VECTOR, NULL_VECTOR);
	
	SetVariantString("!activator");
	AcceptEntityInput(particle, "SetParent", healer);

	SetEntPropEnt(particle, Prop_Send, "m_hControlPointEnts", target, 0);
	SetEntProp(particle, Prop_Send, "m_iControlPointParents", target, _, 0);

	ActivateEntity(particle);
	AcceptEntityInput(particle, "Start");

	return particle;
}

void DisableMedigunLikeEffects(int client, int beam)
{
	AcceptEntityInput(beam, "Stop");

	SetEntPropEnt(beam, Prop_Send, "m_hControlPointEnts", -1, 0);
	SetEntProp(beam, Prop_Send, "m_iControlPointParents", -1, _, 0);

	RemoveEntity(beam);

	StopSound(client, SNDCHAN_AUTO, ")weapons/medigun_heal.wav");

	EmitGameSoundToAll("WeaponMedigun.HealingDetachHealer", client);

	return;
}