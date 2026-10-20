//go:build chimera

// The game's properties (Chimera's docs/game-cores.md): a block of the
// core's memory, the "Game State" domain, laid out as gameState below and
// described by the table in chimera_props.c. After every frame the core
// copies Ikemen GO's values into it; before the next one, whatever a tool
// changed in it (a poke, a freeze) is written back into the game.
package main

/*
#include "chimera_props.h"
*/
import "C"

import (
	"bytes"
	"unsafe"
)

// one fighter's values; the layout is chimera_props.h's
type fighterState struct {
	Life, LifeMax, Power, PowerMax int32
	X, Y, Z, VelX, VelY            float32
	State, Anim                    int32
	GuardPoints, DizzyPoints       int32
	RedLife                        int32
	Facing                         float32
	Present                        uint8
	_                              [3]uint8
}

type gameState struct {
	Frame        int32
	RandomSeed   int32
	Round        int32
	RoundTime    int32
	MatchTime    int32
	Wins         [2]int32
	RoundState   int32
	Fighters     [C.CHIMERA_FIGHTERS]fighterState
}

func init() {
	if unsafe.Sizeof(gameState{}) != C.CHIMERA_GAME_STATE_SIZE || unsafe.Sizeof(fighterState{}) != C.CHIMERA_FIGHTER_SIZE {
		panic("chimera_props: the Go and C layouts of the Game State differ")
	}
}

// what the block held when the core last filled it: a byte that differs now
// was changed by a tool
var publishedState gameState

func stateBlock() *gameState {
	return (*gameState)(unsafe.Pointer(C.chimera_game_state()))
}

// fighter is a root fighter of a side's slot (player 1 is slot 0), or nil
func fighter(i int) *Char {
	if i < 0 || i >= len(sys.chars) || len(sys.chars[i]) == 0 {
		return nil
	}
	return sys.chars[i][0]
}

// publishState copies the game's values into the block (at a frame's end).
func publishState() {
	var g gameState
	g.Frame = sys.frameCounter
	g.RandomSeed = sys.randseed
	g.Round = sys.roundNo
	g.RoundTime = sys.curRoundTime
	g.MatchTime = sys.matchTime
	g.Wins = sys.wins
	if sys.fightScreen.round != nil { // before the fight screen is loaded there is no round
		g.RoundState = sys.roundState()
	}
	for i := range g.Fighters {
		c := fighter(i)
		if c == nil {
			continue
		}
		f := &g.Fighters[i]
		f.Present = 1
		f.Life, f.LifeMax, f.Power, f.PowerMax = c.life, c.lifeMax, c.power, c.powerMax
		f.X, f.Y, f.Z = c.pos[0], c.pos[1], c.pos[2]
		f.VelX, f.VelY = c.vel[0], c.vel[1]
		f.State, f.Anim = c.ss.no, c.animNo
		f.GuardPoints, f.DizzyPoints, f.RedLife = c.guardPoints, c.dizzyPoints, c.redLife
		f.Facing = c.facing
	}
	*stateBlock() = g
	publishedState = g
}

func changed[T any](now, was *T) bool {
	a := unsafe.Slice((*byte)(unsafe.Pointer(now)), unsafe.Sizeof(*now))
	b := unsafe.Slice((*byte)(unsafe.Pointer(was)), unsafe.Sizeof(*was))
	return !bytes.Equal(a, b)
}

// applyPokes writes back into the game what a tool changed in the block
// since it was filled (before the next frame runs). Only the writable
// properties are written; a change to the others is undone at the frame's
// end, when the block is filled again.
func applyPokes() {
	g := stateBlock()
	p := &publishedState
	if !changed(g, p) {
		return
	}
	if g.RandomSeed != p.RandomSeed {
		sys.randseed = g.RandomSeed
	}
	if g.RoundTime != p.RoundTime {
		sys.curRoundTime = g.RoundTime
	}
	for i := range g.Fighters {
		f, was := &g.Fighters[i], &p.Fighters[i]
		c := fighter(i)
		if c == nil || !changed(f, was) {
			continue
		}
		if f.Life != was.Life {
			c.life = f.Life
		}
		if f.Power != was.Power {
			c.power = f.Power
		}
		if f.X != was.X {
			c.pos[0] = f.X
		}
		if f.Y != was.Y {
			c.pos[1] = f.Y
		}
		if f.Z != was.Z {
			c.pos[2] = f.Z
		}
		if f.VelX != was.VelX {
			c.vel[0] = f.VelX
		}
		if f.VelY != was.VelY {
			c.vel[1] = f.VelY
		}
		if f.GuardPoints != was.GuardPoints {
			c.guardPoints = f.GuardPoints
		}
		if f.DizzyPoints != was.DizzyPoints {
			c.dizzyPoints = f.DizzyPoints
		}
		if f.RedLife != was.RedLife {
			c.redLife = f.RedLife
		}
	}
}
