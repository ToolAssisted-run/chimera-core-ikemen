//go:build chimera

// Games made for an Ikemen GO older than the core's (v1.0.0).
//
// A game folder carries a copy of the engine's own scripts, shaders and
// common files, from the release it was made with. The v1.0 engine cannot run
// v0.99's scripts, and Ikemen GO's advice when upgrading a game is to put the
// new release's files over the old ones. The core does that as it reads the
// game, when the game's external/script/main.lua is one of the versions an
// older release had (chimera_legacy_files.txt, written by
// waterbox/make-legacy-list.py):
//   - every file of the game that is an older version of an engine file is
//     set aside, so the engine's own takes its place (the content - the
//     screenpack, characters, stages, music - is never touched);
//   - the game modes Ikemen GO's modules repository has since updated (Boss
//     Rush, Score Challenge, Time Challenge, VS 100 Kumite) are replaced by
//     its current versions (extern/Ikemen-GO-modules), and the Rank module,
//     which that repository has removed, is left out: their old versions stop
//     the v1.0 engine as it starts.
// Such a game's settings are v0.99's defaults with its save/config.json (the
// settings file before v1.0) over them, written as the config.ini v1.0 reads,
// unless it has a config.ini; so is any game's config.json.
package main

import (
	"bytes"
	"crypto/sha1"
	"embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"path"
	"sort"
	"strconv"
	"strings"
)

//go:embed chimera_legacy_files.txt
var legacyFiles string

// v0.99.0's default settings, which a config.json was written over
//
//go:embed chimera_legacy_config.json
var legacyDefaults []byte

// the current versions of the modules (build-ikemen.sh copies them in)
//
//go:embed chimera_modules
var moduleFiles embed.FS

// modules Ikemen GO's modules repository no longer has
var removedModules = map[string]bool{"rank": true}

// whether the game was made for an older Ikemen GO
var legacyGame bool

// legacyStart is called with the game's files in the tree and the engine's
// not yet added.
func legacyStart() {
	known := map[string]map[string]bool{}
	for _, line := range strings.Split(legacyFiles, "\n") {
		if h, p, ok := strings.Cut(line, " "); ok {
			if known[p] == nil {
				known[p] = map[string]bool{}
			}
			known[p][h] = true
		}
	}
	older := func(p string) bool {
		n := walk(p, false)
		if n == nil || n.dir || n.zf == nil || known[p] == nil {
			return false
		}
		rc, err := n.zf.Open()
		if err != nil {
			return false
		}
		b, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			return false
		}
		sum := sha1.Sum(bytes.ReplaceAll(b, []byte{'\r'}, nil))
		return known[p][hex.EncodeToString(sum[:])]
	}
	if !older("external/script/main.lua") {
		return
	}
	legacyGame = true
	var aside []string
	for p := range known {
		if older(p) {
			aside = append(aside, p)
		}
	}
	sort.Strings(aside)
	for _, p := range aside {
		dirName, base := path.Split(p)
		delete(walk(dirName, false).kids, base)
	}

	var replaced, left []string
	if mods := walk("external/mods", false); mods != nil && mods.dir {
		var names []string
		for k := range mods.kids {
			names = append(names, k)
		}
		sort.Strings(names)
		for _, k := range names {
			name := strings.TrimSuffix(k, ".lua")
			if _, err := fs.Stat(moduleFiles, "chimera_modules/"+name); err == nil {
				delete(mods.kids, k)
				replaced = append(replaced, name)
			} else if removedModules[name] {
				left = append(left, mods.kids[k].name)
				delete(mods.kids, k)
			}
		}
		for _, name := range replaced {
			fs.WalkDir(moduleFiles, "chimera_modules/"+name, func(p string, d fs.DirEntry, err error) error {
				if err != nil || d.IsDir() {
					return err
				}
				b, err := moduleFiles.ReadFile(p)
				if err == nil {
					addFile("external/mods/"+strings.TrimPrefix(p, "chimera_modules/"), b, nil, false)
				}
				return err
			})
		}
	}
	fmt.Printf("The game was made for an Ikemen GO older than v1.0: %d of its copies of the engine's files are set aside for the core's own\n", len(aside))
	if len(replaced) > 0 {
		fmt.Printf("Its old modules replaced by their current versions: %s\n", strings.Join(replaced, ", "))
	}
	if len(left) > 0 {
		fmt.Printf("Its old modules left out, as Ikemen GO no longer has them: %s\n", strings.Join(left, ", "))
	}
}

// where each v0.99 setting is in v1.0's config.ini; the ones left out are
// the core's own (picture, sound, controls), or have nothing like them in
// v1.0 (the window, networking, Ratio, which is a module now)
var legacyKeys = []struct{ from, to string }{
	{"AIRamping", "Arcade|AI.Ramping"},
	{"AIRandomColor", "Arcade|AI.RandomColor"},
	{"AISurvivalColor", "Arcade|AI.SurvivalColor"},
	{"AudioDucking", "Sound|AudioDucking"},
	{"AutoGuard", "Options|AutoGuard"},
	{"BarGuard", "Options|GuardBreak"},
	{"BarRedLife", "Options|RedLife"},
	{"BarStun", "Options|Dizzy"},
	{"Credits", "Options|Credits"},
	{"DebugClipboardRows", "Debug|ClipboardRows"},
	{"DebugClsnDarken", "Debug|ClsnDarken"},
	{"DebugConsoleRows", "Debug|ConsoleRows"},
	{"DebugFont", "Debug|Font"},
	{"DebugFontScale", "Debug|FontScale"},
	{"DebugKeys", "Debug|AllowDebugKeys"},
	{"DebugMode", "Debug|AllowDebugMode"},
	{"Difficulty", "Options|Difficulty"},
	{"EscOpensMenu", "Config|EscOpensMenu"},
	{"FirstRun", "Config|FirstRun"},
	{"ForceStageZoomin", "Debug|ForceStageZoomin"},
	{"ForceStageZoomout", "Debug|ForceStageZoomout"},
	{"GameWidth", "Video|GameWidth"},
	{"GameHeight", "Video|GameHeight"},
	{"LifeMul", "Options|Life"},
	{"LoseSimul", "Options|Simul.LoseOnKO"},
	{"LoseTag", "Options|Tag.LoseOnKO"},
	{"MaxAfterImage", "Config|AfterImageMax"},
	{"MaxBgmVolume", "Sound|MaxBGMVolume"},
	{"MaxDrawGames", "Options|Match.MaxDrawGames"},
	{"MaxExplod", "Config|ExplodMax"},
	{"MaxHelper", "Config|HelperMax"},
	{"MaxPlayerProjectile", "Config|ProjectileMax"},
	{"Motif", "Config|Motif"},
	{"PanningRange", "Sound|PanningRange"},
	{"Players", "Config|Players"},
	{"PngSpriteFilter", "Video|RGBSpriteBilinearFilter"},
	{"QuickContinue", "Options|QuickContinue"},
	{"RoundsNumSingle", "Options|Match.Wins"},
	{"RoundsNumSimul", "Options|Simul.Match.Wins"},
	{"RoundsNumTag", "Options|Tag.Match.Wins"},
	{"RoundTime", "Options|Time"},
	{"StartStage", "Debug|StartStage"},
	{"StereoEffects", "Sound|StereoEffects"},
	{"System", "Config|System"},
	{"Team1VS2Life", "Options|Team.SingleVsTeamLife"},
	{"TeamDuplicates", "Options|Team.Duplicates"},
	{"TeamLifeShare", "Options|Team.LifeShare"},
	{"TeamPowerShare", "Options|Team.PowerShare"},
	{"TrainingChar", "Config|TrainingChar"},
	{"TurnsRecoveryBase", "Options|Turns.Recovery.Base"},
	{"TurnsRecoveryBonus", "Options|Turns.Recovery.Bonus"},
	{"VolumeBgm", "Sound|BGMVolume"},
	{"VolumeMaster", "Sound|MasterVolume"},
	{"VolumeSfx", "Sound|WavVolume"},
	{"WavChannels", "Sound|WavChannels"},
	{"ZoomActive", "Config|ZoomActive"},
}

func iniValue(v any) string {
	switch v := v.(type) {
	case bool:
		if v {
			return "1"
		}
		return "0"
	case float64:
		return strconv.FormatFloat(v, 'f', -1, 64)
	case string:
		return v
	case []any:
		var s []string
		for _, e := range v {
			s = append(s, iniValue(e))
		}
		return strings.Join(s, ", ")
	}
	return ""
}

func iniList(v any) []string {
	var out []string
	if l, ok := v.([]any); ok {
		for _, e := range l {
			if s, ok := e.(string); ok && s != "" {
				out = append(out, s)
			}
		}
	}
	return out
}

// legacyConfig writes save/config.ini from save/config.json; called once
// the project's save data is in place, so that its files count.
func legacyConfig() {
	fsys.Lock()
	defer fsys.Unlock()
	if walk("save/config.ini", false) != nil {
		return
	}
	var game, cfg map[string]any
	n := walk("save/config.json", false)
	if n == nil || n.dir {
		if !legacyGame {
			return
		}
	} else {
		b := n.data
		if n.zf != nil {
			rc, err := n.zf.Open()
			if err != nil {
				return
			}
			b, err = io.ReadAll(rc)
			rc.Close()
			if err != nil {
				return
			}
		}
		if err := json.Unmarshal(b, &game); err != nil {
			fmt.Printf("The game's save/config.json could not be read, so its settings are not used: %v\n", err)
		}
	}
	if err := json.Unmarshal(legacyDefaults, &cfg); err != nil {
		return
	}
	for k, v := range game {
		cfg[k] = v
	}

	sections := map[string][]string{}
	put := func(sec, key, value string) {
		sections[sec] = append(sections[sec], key+" = "+value)
	}
	for _, m := range legacyKeys {
		if v, ok := cfg[m.from]; ok {
			sec, key, _ := strings.Cut(m.to, "|")
			put(sec, key, iniValue(v))
		}
	}
	for _, m := range []struct{ from, key string }{{"NumSimul", "Simul"}, {"NumTag", "Tag"}, {"NumTurns", "Turns"}} {
		if l, ok := cfg[m.from].([]any); ok && len(l) == 2 {
			put("Options", m.key+".Min", iniValue(l[0]))
			put("Options", m.key+".Max", iniValue(l[1]))
		}
	}
	// v0.99 lists its shaders and uses the one PostProcessingShader counts
	// to (0: none); v1.0 uses every shader it lists
	shaders := iniList(cfg["ExternalShaders"])
	if i, ok := cfg["PostProcessingShader"].(float64); ok && i >= 1 && int(i) <= len(shaders) {
		put("Video", "ExternalShaders", shaders[int(i)-1])
	} else {
		put("Video", "ExternalShaders", "")
	}
	// the common files: v1.0's own, and whatever the game added to v0.99's
	// list, under a key of its own (v1.0 reads Air, Air1, ... together)
	var defaults map[string]any
	json.Unmarshal(legacyDefaults, &defaults)
	for _, m := range []struct{ from, key string }{{"CommonAir", "Air"}, {"CommonCmd", "Cmd"}, {"CommonConst", "Const"},
		{"CommonStates", "States"}, {"CommonFx", "Fx"}, {"CommonLua", "Lua"}} {
		had := map[string]bool{}
		for _, s := range iniList(defaults[m.from]) {
			had[strings.ToLower(cleanPath(s))] = true
		}
		var extra []string
		for _, s := range iniList(cfg[m.from]) {
			if !had[strings.ToLower(cleanPath(s))] {
				extra = append(extra, s)
			}
		}
		if len(extra) > 0 {
			put("Common", m.key+"1", strings.Join(extra, ", "))
		}
	}
	if mods := iniList(cfg["Modules"]); len(mods) > 0 {
		put("Common", "Modules", strings.Join(mods, ", "))
	}

	var ini strings.Builder
	ini.WriteString("; made by the Chimera core from Ikemen GO v0.99's settings and the game's save/config.json\n")
	for _, sec := range []string{"Common", "Options", "Config", "Debug", "Video", "Sound", "Arcade"} {
		if len(sections[sec]) == 0 {
			continue
		}
		fmt.Fprintf(&ini, "\n[%s]\n%s\n", sec, strings.Join(sections[sec], "\n"))
	}
	addFile("save/config.ini", []byte(ini.String()), nil, false)
	if game != nil {
		fmt.Printf("The game's settings are taken from its save/config.json\n")
	} else {
		fmt.Printf("The game's settings are Ikemen GO v0.99's defaults\n")
	}
}
