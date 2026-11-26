package term

import "core:os"
import "core:strings"
import "core:testing"

// ---------------------------------------------------------------- the config file

@(test)
test_config_defaults :: proc(tt: ^testing.T) {
	c := config_default()
	defer config_free(&c)
	testing.expect_value(tt, c.font_size, 12)
	testing.expect_value(tt, c.theme, "glass")
	testing.expect_value(tt, c.scrollback, 10000)
	testing.expect(tt, c.cursor_glow && c.ligatures && c.osc52 && c.bell)
	fams := font_families(&c)
	testing.expect_value(tt, len(fams), 5)
	testing.expect_value(tt, fams[0], "MesloLGS NF")
	testing.expect_value(tt, fams[4], "DejaVu Sans Mono")
}

@(test)
test_config_parse :: proc(tt: ^testing.T) {
	c := config_default()
	defer config_free(&c)
	config_parse(&c, `# a comment
font = "JetBrainsMono Nerd Font", DejaVu Sans Mono
font_size = 14.5
theme = Graphite
opacity=0.4
blur = off
padding = 20
cursor = bar
scrollback = 500
container = fedora-dev
ligatures = no
bell = none
scroll_lines = 5
cursor-glow = false
bogus_key = 1
font_size = banana
no equals sign here
`)
	testing.expect_value(tt, c.font_size, 14.5)
	testing.expect_value(tt, c.theme, "graphite")
	testing.expect_value(tt, c.opacity, 0.4)
	testing.expect(tt, !c.blur)
	testing.expect_value(tt, c.padding, 20)
	testing.expect_value(tt, c.cursor, Cursor_Style.Bar)
	testing.expect_value(tt, c.scrollback, 500)
	testing.expect_value(tt, c.container, "fedora-dev")
	testing.expect(tt, !c.ligatures)
	testing.expect(tt, !c.bell)
	testing.expect_value(tt, c.scroll_lines, 5)
	testing.expect(tt, !c.cursor_glow)
	fams := font_families(&c)
	testing.expect_value(tt, len(fams), 2)
	testing.expect_value(tt, fams[0], "JetBrainsMono Nerd Font")
	// what it did not understand is kept (the bad number keeps the old size)
	testing.expect_value(tt, len(c.unknown), 3)
	testing.expect_value(tt, c.font_size, 14.5)
}

@(test)
test_config_limits :: proc(tt: ^testing.T) {
	c := config_default()
	defer config_free(&c)
	testing.expect(tt, !config_set(&c, "font_size", "2"))
	testing.expect(tt, !config_set(&c, "opacity", "1.5"))
	testing.expect(tt, config_set(&c, "opacity", "-1"))
	testing.expect(tt, !config_set(&c, "cursor", "star"))
	testing.expect(tt, !config_set(&c, "scrollback", "-5"))
	testing.expect(tt, config_set(&c, "  Scrollback ", " 0 "))
	testing.expect_value(tt, c.scrollback, 0)
}

@(test)
test_config_sample_parses_clean :: proc(tt: ^testing.T) {
	c := config_default()
	defer config_free(&c)
	config_parse(&c, CONFIG_SAMPLE)
	testing.expect_value(tt, len(c.unknown), 0)
	d := config_default()
	defer config_free(&d)
	testing.expect_value(tt, c.font, d.font)
	testing.expect_value(tt, c.font_size, d.font_size)
	testing.expect_value(tt, c.opacity, d.opacity)
	testing.expect_value(tt, c.padding, d.padding)
	testing.expect_value(tt, c.scrollback, d.scrollback)
	testing.expect_value(tt, c.columns, d.columns)
}

// ---------------------------------------------------------------- zsh

@(test)
test_zsh_block_text :: proc(tt: ^testing.T) {
	old := "export A=1\nalias ll='ls -l'\n"
	added := zsh_add_block(old, context.temp_allocator)
	testing.expect(tt, zsh_has_block(added))
	testing.expect(tt, strings.has_prefix(added, old))
	// twice is once
	testing.expect_value(tt, zsh_add_block(added, context.temp_allocator), added)
	// out again: exactly the old text
	testing.expect_value(tt, zsh_remove_block(added, context.temp_allocator), old)
	// no trailing newline: the file ends with one afterwards (the only difference)
	old2 := "export B=2"
	testing.expect_value(tt, zsh_remove_block(zsh_add_block(old2, context.temp_allocator), context.temp_allocator), "export B=2\n")
	testing.expect_value(tt, zsh_remove_block(zsh_add_block("", context.temp_allocator), context.temp_allocator), "")
	// text after the block stays
	mid := strings.concatenate({added, "export C=3\n"}, context.temp_allocator)
	testing.expect_value(tt, zsh_remove_block(mid, context.temp_allocator), strings.concatenate({old, "export C=3\n"}, context.temp_allocator))
}

@(private="file") temp_home :: proc(name: string) -> string {
	dir := strings.concatenate({"/tmp/iris-terminal-test-", name}, context.temp_allocator)
	os.remove_all(dir)
	os.make_directory_all(dir)
	return dir
}

@(test)
test_zsh_setup_roundtrip :: proc(tt: ^testing.T) {
	home := temp_home("zsh")
	defer os.remove_all(home)
	cfg := strings.concatenate({home, "/.config/iris-terminal"}, context.temp_allocator)
	zshrc := strings.concatenate({home, "/.zshrc"}, context.temp_allocator)
	original := "export KEEP=me\n"
	testing.expect(tt, os.write_entire_file(zshrc, transmute([]u8)original) == nil)

	res, ok := zsh_setup(home, cfg)
	testing.expect(tt, ok)
	testing.expect(tt, res.added_block)
	testing.expect(tt, res.backup != "")
	delete(res.backup)
	init, _ := os.read_entire_file(strings.concatenate({cfg, "/zsh/init.zsh"}, context.temp_allocator), context.temp_allocator)
	testing.expect(tt, strings.contains(string(init), "OSC 133") || strings.contains(string(init), "133;"))
	testing.expect(tt, len(init) > 1000)
	backup, _ := os.read_entire_file(strings.concatenate({zshrc, ZSH_BACKUP_SUFFIX}, context.temp_allocator), context.temp_allocator)
	testing.expect_value(tt, string(backup), original)
	text, _ := os.read_entire_file(zshrc, context.temp_allocator)
	testing.expect(tt, zsh_has_block(string(text)))

	// again: nothing new
	res2, ok2 := zsh_setup(home, cfg)
	testing.expect(tt, ok2)
	testing.expect(tt, !res2.added_block)
	text2, _ := os.read_entire_file(zshrc, context.temp_allocator)
	testing.expect_value(tt, string(text2), string(text))

	removed, ok3 := zsh_remove(home, cfg)
	testing.expect(tt, ok3 && removed)
	text3, _ := os.read_entire_file(zshrc, context.temp_allocator)
	testing.expect_value(tt, string(text3), original)
	testing.expect(tt, !os.exists(strings.concatenate({cfg, "/zsh/init.zsh"}, context.temp_allocator)))
}

@(test)
test_zsh_setup_without_zshrc :: proc(tt: ^testing.T) {
	home := temp_home("zsh2")
	defer os.remove_all(home)
	cfg := strings.concatenate({home, "/.config/iris-terminal"}, context.temp_allocator)
	res, ok := zsh_setup(home, cfg)
	testing.expect(tt, ok && res.added_block)
	testing.expect_value(tt, res.backup, "")
	removed, ok2 := zsh_remove(home, cfg)
	testing.expect(tt, ok2 && removed)
	// the file was only ours: it is gone
	testing.expect(tt, !os.exists(strings.concatenate({home, "/.zshrc"}, context.temp_allocator)))
}

// ---------------------------------------------------------------- niri

@(test)
test_niri_version :: proc(tt: ^testing.T) {
	major, minor, ok := parse_niri_version("niri 26.04 (abc1234)")
	testing.expect(tt, ok)
	testing.expect_value(tt, major, 26)
	testing.expect_value(tt, minor, 4)
	testing.expect(tt, niri_has_blur("niri 26.04"))
	testing.expect(tt, niri_has_blur("niri 27.01 (x)"))
	testing.expect(tt, !niri_has_blur("niri 25.11"))
	testing.expect(tt, !niri_has_blur("niri 26.02"))
	testing.expect(tt, !niri_has_blur(""))
	testing.expect(tt, !niri_has_blur("something else"))
}

@(test)
test_niri_include_text :: proc(tt: ^testing.T) {
	old := "input {\n    keyboard {}\n}\n"
	added := niri_add_include(old, context.temp_allocator)
	testing.expect(tt, niri_has_include(added))
	testing.expect_value(tt, niri_add_include(added, context.temp_allocator), added)
	testing.expect_value(tt, niri_remove_include(added, context.temp_allocator), old)
}

@(test)
test_niri_kdl :: proc(tt: ^testing.T) {
	with := niri_kdl(14, true, context.temp_allocator)
	testing.expect(tt, strings.contains(with, "io.github.tulip_labs.IrisTerminal"))
	testing.expect(tt, strings.contains(with, "geometry-corner-radius 14"))
	testing.expect(tt, strings.contains(with, "blur true"))
	without := niri_kdl(10, false, context.temp_allocator)
	testing.expect(tt, !strings.contains(without, "blur true"))
	testing.expect(tt, strings.contains(without, "geometry-corner-radius 10"))
}

@(test)
test_niri_setup_roundtrip :: proc(tt: ^testing.T) {
	dir := temp_home("niri")
	defer os.remove_all(dir)
	cfg := strings.concatenate({dir, "/config.kdl"}, context.temp_allocator)
	// no config: an error, nothing written
	_, err0 := niri_setup(dir, 14, true)
	testing.expect_value(tt, err0, Niri_Error.No_Config)
	original := "// mine\nlayout {\n    gaps 8\n}\n"
	testing.expect(tt, os.write_entire_file(cfg, transmute([]u8)original) == nil)
	res, err := niri_setup(dir, 14, true)
	testing.expect_value(tt, err, Niri_Error.None)
	testing.expect(tt, res.added_include)
	delete(res.backup)
	rule, _ := os.read_entire_file(strings.concatenate({dir, "/", NIRI_KDL_NAME}, context.temp_allocator), context.temp_allocator)
	testing.expect(tt, strings.contains(string(rule), "blur true"))
	text, _ := os.read_entire_file(cfg, context.temp_allocator)
	testing.expect(tt, niri_has_include(string(text)))
	// the second time changes nothing
	res2, err2 := niri_setup(dir, 14, true)
	testing.expect_value(tt, err2, Niri_Error.None)
	testing.expect(tt, !res2.added_include)
	removed, err3 := niri_remove(dir)
	testing.expect_value(tt, err3, Niri_Error.None)
	testing.expect(tt, removed)
	back, _ := os.read_entire_file(cfg, context.temp_allocator)
	testing.expect_value(tt, string(back), original)
	testing.expect(tt, !os.exists(strings.concatenate({dir, "/", NIRI_KDL_NAME}, context.temp_allocator)))
}

// ---------------------------------------------------------------- themes

@(test)
test_themes :: proc(tt: ^testing.T) {
	d := theme_by_name("glass", true)
	l := theme_by_name("glass", false)
	testing.expect(tt, d.dark && !l.dark)
	testing.expect_value(tt, theme_by_name("glass-light", true).dark, false)
	testing.expect_value(tt, theme_by_name("nonsense", false).dark, false)
	testing.expect_value(tt, theme_by_name("graphite", false).name, "graphite")
	testing.expect_value(tt, theme_by_name("paper", true).dark, false)
	// magenta is a rose: red above blue, green lowest of the three
	for th in ([]Theme{d, l}) {
		m := th.ansi[5]
		testing.expect(tt, m.r > m.b && m.b > m.g)
	}
	testing.expect(tt, parse_scheme("'prefer-dark'"))
	testing.expect(tt, !parse_scheme("'prefer-light'"))
	testing.expect(tt, parse_scheme("'default'", true))
	testing.expect(tt, !parse_scheme("'default'", false))
}
