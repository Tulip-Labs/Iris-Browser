// `iris-terminal --setup-zsh` and `--remove-zsh`: a refined zsh setup in
// ~/.config/iris-terminal/zsh/init.zsh, and one block in ~/.zshrc that
// sources it (after a backup, removed again by --remove-zsh).
package term

import "core:os"
import "core:strings"

ZSH_BEGIN :: "# >>> iris-terminal >>>"
ZSH_END :: "# <<< iris-terminal <<<"
ZSH_BACKUP_SUFFIX :: ".before-iris-terminal"

@(private) ZSH_BLOCK :: ZSH_BEGIN + `
# Written by iris-terminal --setup-zsh; take it out with iris-terminal --remove-zsh.
# IRIS_PROMPT=0 (set before this line) keeps your own prompt.
[[ -r "${XDG_CONFIG_HOME:-$HOME/.config}/iris-terminal/zsh/init.zsh" ]] && source "${XDG_CONFIG_HOME:-$HOME/.config}/iris-terminal/zsh/init.zsh"
` + ZSH_END + "\n"

zsh_has_block :: proc(text: string) -> bool {
	return strings.contains(text, ZSH_BEGIN) && strings.contains(text, ZSH_END)
}

/// the text of .zshrc with the block added at its end
zsh_add_block :: proc(text: string, allocator := context.allocator) -> string {
	if zsh_has_block(text) do return strings.clone(text, allocator)
	if len(text) == 0 do return strings.clone(ZSH_BLOCK, allocator)
	sep := strings.has_suffix(text, "\n") ? "\n" : "\n\n"
	return strings.concatenate({text, sep, ZSH_BLOCK}, allocator)
}

/// the text with the block (and the blank line before it) taken out
zsh_remove_block :: proc(text: string, allocator := context.allocator) -> string {
	b := strings.index(text, ZSH_BEGIN)
	if b < 0 do return strings.clone(text, allocator)
	e := strings.index(text[b:], ZSH_END)
	if e < 0 do return strings.clone(text, allocator)
	end := b + e + len(ZSH_END)
	if end < len(text) && text[end] == '\n' do end += 1
	start := b
	// the blank line that was put before it
	if start >= 2 && text[start - 1] == '\n' && text[start - 2] == '\n' do start -= 1
	return strings.concatenate({text[:start], text[end:]}, allocator)
}

Zsh_Result :: struct {
	added_block: bool,
	wrote_init:  bool,
	backup:      string, // where the old .zshrc was copied ("" when it was not)
	zshrc:       string,
	init:        string,
}

/// the folder of the zsh files: $ZDOTDIR, or the home folder
zsh_dir :: proc(home: string) -> string {
	if d := os.get_env("ZDOTDIR", context.temp_allocator); len(d) > 0 do return d
	return home
}

@(private) read_text :: proc(path: string) -> (string, bool) {
	b, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return "", false
	return string(b), true
}

/// writes a file only when its content differs
write_if_changed :: proc(path, content: string) -> bool {
	if old, ok := read_text(path); ok && old == content do return true
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, content) != nil do return false
	return os.rename(tmp, path) == nil
}

/// puts init.zsh in `cfg_dir`/zsh and the block in .zshrc (after one backup)
zsh_setup :: proc(home, cfg_dir: string) -> (res: Zsh_Result, ok: bool) {
	zdir := strings.concatenate({cfg_dir, "/zsh"}, context.temp_allocator)
	os.make_directory_all(zdir)
	res.init = strings.concatenate({zdir, "/init.zsh"}, context.temp_allocator)
	if !write_if_changed(res.init, ZSH_INIT) do return res, false
	res.wrote_init = true
	res.zshrc = strings.concatenate({zsh_dir(home), "/.zshrc"}, context.temp_allocator)
	old, had := read_text(res.zshrc)
	if zsh_has_block(old) do return res, true
	if had {
		backup := strings.concatenate({res.zshrc, ZSH_BACKUP_SUFFIX}, context.temp_allocator)
		if !os.exists(backup) {
			if os.write_entire_file(backup, old) != nil do return res, false
			res.backup = strings.clone(backup)
		}
	}
	text := zsh_add_block(old, context.temp_allocator)
	if os.write_entire_file(res.zshrc, text) != nil do return res, false
	res.added_block = true
	return res, true
}

/// undoes zsh_setup: the block out of .zshrc (the file goes when it was
/// only ours), init.zsh deleted
zsh_remove :: proc(home, cfg_dir: string) -> (removed_block: bool, ok: bool) {
	zshrc := strings.concatenate({zsh_dir(home), "/.zshrc"}, context.temp_allocator)
	if old, had := read_text(zshrc); had && zsh_has_block(old) {
		text := zsh_remove_block(old, context.temp_allocator)
		backup := strings.concatenate({zshrc, ZSH_BACKUP_SUFFIX}, context.temp_allocator)
		if len(strings.trim_space(text)) == 0 && !os.exists(backup) {
			os.remove(zshrc)
		} else if os.write_entire_file(zshrc, text) != nil {
			return false, false
		}
		removed_block = true
	}
	os.remove(strings.concatenate({cfg_dir, "/zsh/init.zsh"}, context.temp_allocator))
	os.remove(strings.concatenate({cfg_dir, "/zsh"}, context.temp_allocator))
	return removed_block, true
}

/// the refined zsh setup: history, completion with a menu, keys, the
/// plugins that are installed, and a fast prompt with no plugin
ZSH_INIT :: `# Iris Terminal: a refined zsh. Written by iris-terminal --setup-zsh and
# sourced from ~/.zshrc; "iris-terminal --remove-zsh" takes it all out again.
# Set IRIS_PROMPT=0 before the source line to keep your own prompt.
[[ -o interactive ]] || return 0

# --- history
: ${HISTFILE:=${ZDOTDIR:-$HOME}/.zsh_history}
HISTSIZE=100000
SAVEHIST=100000
setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS HIST_VERIFY
setopt AUTO_CD AUTO_PUSHD PUSHD_IGNORE_DUPS PUSHD_SILENT INTERACTIVE_COMMENTS NO_BEEP NO_FLOW_CONTROL
setopt COMPLETE_IN_WORD ALWAYS_TO_END

# --- completion: a menu, case-insensitive, coloured like ls
if (( ! $+functions[compdef] )); then
  autoload -Uz compinit
  () {
    setopt local_options extended_glob
    local d="${XDG_CACHE_HOME:-$HOME/.cache}/iris-terminal"
    [[ -d $d ]] || mkdir -p "$d"
    local dump="$d/zcompdump"
    if [[ -n ${dump}(#qN.mh-24) ]]; then compinit -C -d "$dump"; else compinit -d "$dump"; fi
  }
fi
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
zstyle ':completion:*' group-name ''
zstyle ':completion:*:descriptions' format '%F{8}-- %d --%f'
zstyle ':completion:*:warnings' format '%F{1}no matches%f'
zstyle ':completion:*' use-cache yes
zstyle ':completion:*' cache-path "${XDG_CACHE_HOME:-$HOME/.cache}/iris-terminal/zcompcache"

# --- keys (xterm: what Iris Terminal sends)
bindkey -e
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey '^[[A' up-line-or-beginning-search
bindkey '^[OA' up-line-or-beginning-search
bindkey '^[[B' down-line-or-beginning-search
bindkey '^[OB' down-line-or-beginning-search
bindkey '^[[H' beginning-of-line
bindkey '^[OH' beginning-of-line
bindkey '^[[F' end-of-line
bindkey '^[OF' end-of-line
bindkey '^[[3~' delete-char
bindkey '^[[1;5C' forward-word
bindkey '^[[1;5D' backward-word
bindkey '^[[1;3C' forward-word
bindkey '^[[1;3D' backward-word
bindkey '^[[3;5~' kill-word
bindkey '^H' backward-kill-word
bindkey '^[[Z' reverse-menu-complete

# --- colour
if [[ -z $LS_COLORS ]] && (( $+commands[dircolors] )); then eval "$(dircolors -b)"; fi
alias ls='ls --color=auto'
alias grep='grep --color=auto'

# --- plugins, when they are installed (Fedora, Arch, Debian, Homebrew, your home)
_iris_plugin() {
  local name=$1 f
  local -a found
  found=(
    /usr/share/$name/$name.zsh
    /usr/share/zsh/plugins/$name/$name.zsh
    /usr/share/zsh*/*/$name.zsh(N)
    /usr/share/zsh*/*/*/$name.zsh(N)
    /home/linuxbrew/.linuxbrew/share/$name/$name.zsh
    /opt/homebrew/share/$name/$name.zsh
    /usr/local/share/$name/$name.zsh
    ${XDG_DATA_HOME:-$HOME/.local/share}/$name/$name.zsh
    ${XDG_DATA_HOME:-$HOME/.local/share}/zsh/plugins/$name/$name.zsh
    $HOME/.zsh/$name/$name.zsh
  )
  for f in $found; do
    [[ -r $f ]] && { source "$f"; return 0 }
  done
  return 1
}
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'
_iris_plugin zsh-autosuggestions
if (( $+commands[fzf] )); then
  if [[ -r /usr/share/fzf/key-bindings.zsh ]]; then
    source /usr/share/fzf/key-bindings.zsh
    [[ -r /usr/share/fzf/completion.zsh ]] && source /usr/share/fzf/completion.zsh
  elif [[ -r /usr/share/fzf/shell/key-bindings.zsh ]]; then
    source /usr/share/fzf/shell/key-bindings.zsh
  else
    source <(fzf --zsh 2>/dev/null) 2>/dev/null
  fi
fi

# --- the prompt: no plugin, no subprocess (the branch is read from .git/HEAD)
if [[ ${IRIS_PROMPT:-1} != 0 ]]; then
  autoload -Uz add-zsh-hook
  zmodload zsh/datetime 2>/dev/null

  # the symbols: Nerd Font ones when Iris Terminal found them in the font
  if [[ ${IRIS_TERMINAL_NERD:-0} == 1 ]]; then
    typeset -g _ip_branch=$''
  else
    typeset -g _ip_branch=$'⎇'
  fi
  typeset -g _ip_t0 _ip_first=1 _ip_ctr _ip_env

  # the container this shell runs in (distrobox, toolbox)
  if [[ -n $CONTAINER_ID ]]; then
    _ip_ctr=$CONTAINER_ID
  elif [[ -r /run/.containerenv ]]; then
    () {
      local l
      for l in "${(@f)$(</run/.containerenv)}"; do
        [[ $l == name=* ]] && { _ip_ctr=${${l#name=}//\"/}; break }
      done
    }
  fi

  _ip_git_branch() {
    local d=$PWD head g ref
    while true; do
      if [[ -d $d/.git ]]; then
        head=$d/.git/HEAD
        break
      elif [[ -f $d/.git ]]; then
        read -r g < $d/.git 2>/dev/null
        g=${g#gitdir: }
        [[ $g == /* ]] || g=$d/$g
        head=$g/HEAD
        break
      fi
      [[ $d == / || -z $d ]] && return 1
      d=${d:h}
    done
    [[ -r $head ]] || return 1
    read -r ref < $head 2>/dev/null
    if [[ $ref == "ref: refs/heads/"* ]]; then
      REPLY=${ref#ref: refs/heads/}
    else
      REPLY=${ref[1,7]}
    fi
  }

  # OSC 7: the directory, for new windows and for the title
  _ip_osc7() {
    local LC_ALL=C p=$PWD out= c hex i
    if [[ $p == *[^a-zA-Z0-9/._~-]* ]]; then
      for (( i = 1; i <= ${#p}; i++ )); do
        c=${p[i]}
        if [[ $c == [a-zA-Z0-9/._~-] ]]; then
          out+=$c
        else
          printf -v hex '%%%02X' "'$c"
          out+=$hex
        fi
      done
    else
      out=$p
    fi
    print -n -- $'\e]7;file://'${HOST}${out}$'\a'
  }

  _ip_duration() {
    local -i s=${1%.*}
    local frac=${1#*.}
    if (( s >= 3600 )); then print -r -- "$(( s / 3600 ))h $(( s % 3600 / 60 ))m"
    elif (( s >= 60 )); then print -r -- "$(( s / 60 ))m $(( s % 60 ))s"
    else print -r -- "${s}.${frac[1]}s"
    fi
  }

  _ip_precmd() {
    local ret=$?
    # OSC 133: the last command ended (not before the first prompt)
    if (( _ip_first )); then _ip_first=0; else print -n -- $'\e]133;D;'$ret$'\a'; fi
    local dur=
    if [[ -n $_ip_t0 ]]; then
      local t=$(( EPOCHREALTIME - _ip_t0 ))
      _ip_t0=
      (( t >= 2 )) && dur=$(_ip_duration $t)
    fi
    _ip_osc7
    print -n -- $'\e]2;'${(%):-%n@%m}': '${(%):-%~}$'\a'

    local dir=${${(%):-%~}//\%/%%}
    local left=
    [[ -n $_ip_ctr ]] && left+="%F{6}⬢ ${_ip_ctr//\%/%%}%f  "
    left+="%B${dir}%b"
    _ip_git_branch && left+="  %F{8}${_ip_branch} ${REPLY//\%/%%}%f"
    if [[ -n $DEVBOX_SHELL_ENABLED ]]; then left+="  %F{3}devbox%f"
    elif [[ -n $IN_NIX_SHELL ]]; then left+="  %F{3}nix%f"
    fi
    local char='%F{15}❯%f'
    local right=
    if (( ret != 0 )); then
      char='%F{1}❯%f'
      right+="%F{1}✘ ${ret}%f"
    fi
    [[ -n $dur ]] && right+="${right:+  }%F{8}${dur}%f"
    PROMPT=$'%{\e]133;A\a%}'"${left}"$'\n'"${char} "$'%{\e]133;B\a%}'
    RPROMPT=$right
    PS2='%F{8}…%f '
  }

  _ip_preexec() {
    _ip_t0=$EPOCHREALTIME
    print -n -- $'\e]133;C\a'
    print -n -- $'\e]2;'${${1[1,60]}//[[:cntrl:]]/ }$'\a'
  }

  precmd_functions=(_ip_precmd $precmd_functions)
  add-zsh-hook preexec _ip_preexec
  add-zsh-hook chpwd _ip_osc7
  PROMPT_EOL_MARK='%F{8}⏎%f'
fi

# --- syntax highlighting goes last: it wraps every widget
_iris_plugin zsh-syntax-highlighting
unfunction _iris_plugin 2>/dev/null
true
`
