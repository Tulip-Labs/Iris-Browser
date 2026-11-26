#!/bin/sh
# Printed inside the terminal by the functional tests (iris-terminal --exec):
# colours, wide and combining characters, the alternate screen, a link, a
# title, cursor addressing. tests/expected-screen.txt is what must be left on
# the screen, character for character.
printf '\033[2J\033[H'
printf '\033[31mred\033[0m \033[1;32mbold\033[0m \033[38;2;10;20;30mtrue\033[0m \033[38;5;208morange\033[0m\n'
printf '\033[48;2;255;0;0m  \033[48;2;0;255;0m  \033[48;2;0;0;255m  \033[0m|\n'
printf '\346\274\242\345\255\227 wide|\n'
printf 'e\314\201 combining|\n'
printf '\033]8;;https://example.org/x\033\\link\033]8;;\033\\ after\n'
printf '\033]0;iris title\007'
printf '\033[?1049h\033[2J\033[HALT SCREEN\033[?1049l'
printf 'back on main\n'
printf '\033[8;10Hat 8,10\n'
printf '\033[4m\033[4:3mcurly\033[0m \033[9mstrike\033[0m \033[7mrev\033[0m\n'
printf '0123456789\033[3D\033[K!\n'
printf 'a\tb\n'
printf 'done\n'
