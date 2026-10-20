/* chimera_props.h - the Game State block (chimera_props.go fills it). */
#ifndef CHIMERA_PROPS_H
#define CHIMERA_PROPS_H

#include <stdint.h>

/* the root fighters: four a side (Ikemen GO's MaxSimul), player 1 first */
#define CHIMERA_FIGHTERS 8
#define CHIMERA_FIGHTER_SIZE 64
#define CHIMERA_MATCH_SIZE 32
#define CHIMERA_GAME_STATE_SIZE (CHIMERA_MATCH_SIZE + CHIMERA_FIGHTERS * CHIMERA_FIGHTER_SIZE)

uint8_t *chimera_game_state(void);

#endif
