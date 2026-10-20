#!/usr/bin/env python3
"""Writes waterbox/input-names.h from waterbox/waterbox.config: the buttons
in the config's order, for the test harness (a movie line names what is held
by these tokens, the config's names without spaces). The core has no axes.

usage: tools/gen-input-names.py   (from the repository's top)"""
import json

cfg = json.load(open("waterbox/waterbox.config"))
buttons = cfg["input"]["buttons"]
with open("waterbox/input-names.h", "w") as o:
    o.write("/* input-names.h - the buttons in waterbox.config's order, for the test\n"
            " * harness: a movie line names what is held by these tokens (the config's\n"
            " * names without spaces). Written by tools/gen-input-names.py; the gate\n"
            " * checks the two agree. */\n")
    o.write("static const char *const gate_button_tokens[] = {\n")
    for b in buttons:
        o.write(f'\t"{b.replace(" ", "")}",\n')
    o.write("};\n")
    o.write(f"#define GATE_BTN_COUNT {len(buttons)}\n")
    o.write("/* no axes */\n")
    o.write("static const char *const gate_axis_tokens[1] = { \"\" };\n")
    o.write("#define GATE_AXIS_COUNT 0\n")
    o.write("static const int gate_axis_neutral[1] = { 0 };\n")
print(len(buttons), "buttons")
