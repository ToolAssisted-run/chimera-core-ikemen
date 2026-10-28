/* chimera_props.c - the Game State domain and its property table
 * (Chimera's docs/game-cores.md). The block is filled by the Go half after
 * every frame (chimera_props.go: publishState) and what a tool changed in it
 * is written back before the next frame (applyPokes). */
#include <stdio.h>
#include <string.h>

#include <emulibc.h>

#include "chimera_props.h"

static uint8_t game_state[CHIMERA_GAME_STATE_SIZE];

uint8_t *chimera_game_state(void)
{
	return game_state;
}

ECL_EXPORT int GetMemoryDomainCount(void) { return 1; }
ECL_EXPORT const char *GetMemoryDomainName(int i) { return i == 0 ? "Game State" : ""; }
ECL_EXPORT uint8_t *GetMemoryDomainPtr(int i) { return i == 0 ? game_state : NULL; }
ECL_EXPORT int64_t GetMemoryDomainSize(int i) { return i == 0 ? CHIMERA_GAME_STATE_SIZE : 0; }
ECL_EXPORT int GetMemoryDomainWritable(int i) { return i == 0; }

struct prop { const char *name, *type, *desc; int offset, writable; const char *values; };

static const struct prop match_props[] = {
	{ "Match.Frame", "s32", "property.match_frame", 0, 0, NULL },
	{ "Match.Random Seed", "s32", "property.match_random_seed", 4, 1, NULL },
	{ "Match.Round", "s32", "property.match_round", 8, 0, NULL },
	{ "Match.Round Time", "s32", "property.match_round_time", 12, 1, NULL },
	{ "Match.Match Time", "s32", "property.match_match_time", 16, 0, NULL },
	{ "Match.Wins", "s32", "property.match_wins", 20, 0, NULL },
	{ "Match.Round State", "s32", "property.match_round_state", 28, 0,
	  "{\"0\": \"Before the intro\", \"1\": \"Intro\", \"2\": \"Fight\", \"3\": \"Ending\", \"4\": \"Over\"}" },
};

static const struct prop fighter_props[] = {
	{ "Life", "s32", "property.life", 0, 1, NULL },
	{ "Life Max", "s32", "property.life_max", 4, 0, NULL },
	{ "Power", "s32", "property.power", 8, 1, NULL },
	{ "Power Max", "s32", "property.power_max", 12, 0, NULL },
	{ "X", "f32", "property.x", 16, 1, NULL },
	{ "Y", "f32", "property.y", 20, 1, NULL },
	{ "Z", "f32", "property.z", 24, 1, NULL },
	{ "Velocity X", "f32", "property.velocity_x", 28, 1, NULL },
	{ "Velocity Y", "f32", "property.velocity_y", 32, 1, NULL },
	{ "State", "s32", "property.fighter_state", 36, 0, NULL },
	{ "Animation", "s32", "property.animation", 40, 0, NULL },
	{ "Guard Points", "s32", "property.guard_points", 44, 1, NULL },
	{ "Dizzy Points", "s32", "property.dizzy_points", 48, 1, NULL },
	{ "Red Life", "s32", "property.red_life", 52, 1, NULL },
	{ "Facing", "f32", "property.facing", 56, 0, NULL },
	{ "Present", "bool", "property.present", 60, 0, NULL },
};

static char table[16384];

static void add(int *n, const struct prop *p, const char *name, const char *group, int offset, int count)
{
	*n += snprintf(table + *n, sizeof table - *n,
		"%s\n    { \"name\": \"%s\", \"domain\": \"Game State\", \"offset\": %d, \"type\": \"%s\", \"group\": \"%s\"",
		*n > 32 ? "," : "", name, offset, p->type, group);
	if (count > 1)
		*n += snprintf(table + *n, sizeof table - *n, ", \"count\": %d, \"stride\": %d, \"first\": 1", count, CHIMERA_FIGHTER_SIZE);
	if (!p->writable)
		*n += snprintf(table + *n, sizeof table - *n, ", \"writable\": false");
	if (p->values)
		*n += snprintf(table + *n, sizeof table - *n, ", \"values\": %s", p->values);
	*n += snprintf(table + *n, sizeof table - *n, ", \"description\": \"%s\" }", p->desc);
}

ECL_EXPORT const char *GetGameProperties(void)
{
	if (table[0])
		return table;
	int n = snprintf(table, sizeof table, "{\n  \"properties\": [");
	for (size_t i = 0; i < sizeof match_props / sizeof *match_props; i++) {
		const struct prop *p = &match_props[i];
		if (p->offset == 20) {
			/* the two sides' wins: an array of two */
			n += snprintf(table + n, sizeof table - n,
				"%s\n    { \"name\": \"%s\", \"domain\": \"Game State\", \"offset\": 20, \"type\": \"s32\", \"group\": \"Match\", \"count\": 2, \"writable\": false, \"description\": \"%s\" }",
				",", p->name, p->desc);
			continue;
		}
		add(&n, p, p->name, "Match", p->offset, 1);
	}
	for (size_t i = 0; i < sizeof fighter_props / sizeof *fighter_props; i++) {
		char name[64];
		snprintf(name, sizeof name, "Player.%s", fighter_props[i].name);
		add(&n, &fighter_props[i], name, "Players", CHIMERA_MATCH_SIZE + fighter_props[i].offset, CHIMERA_FIGHTERS);
	}
	snprintf(table + n, sizeof table - n, "\n  ]\n}\n");
	return table;
}
