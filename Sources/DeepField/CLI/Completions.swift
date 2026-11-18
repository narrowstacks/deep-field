/// Shell completion scripts for `deepfield completion`. They ask `deepfield` itself for the
/// commands, scenes, keys, presets and events, so they stay current as those change.
enum Completions {
    static let zsh = #"""
        #compdef deepfield

        _deepfield() {
          local -a cmds
          if (( CURRENT == 2 )); then
            cmds=(${(f)"$(deepfield help --commands 2>/dev/null)"})
            _describe 'command' cmds
            return
          fi
          local cmd=$words[2]
          case $cmd in
            scene)
              if (( CURRENT == 3 )); then
                compadd -- random ${(f)"$(deepfield scenes --names 2>/dev/null)"}
              else
                compadd -S '=' -- ${(f)"$(deepfield keys --all --names 2>/dev/null)"}
              fi ;;
            set)
              compadd -S '=' -- ${(f)"$(deepfield keys --all --names 2>/dev/null)"} ;;
            get|reset)
              compadd -- ${(f)"$(deepfield keys --all --names 2>/dev/null)"} ;;
            keys|presets)
              [[ $words[CURRENT-1] == --scene ]] && compadd -- ${(f)"$(deepfield scenes --names 2>/dev/null)"} ;;
            preset)
              if (( CURRENT == 3 )); then
                compadd -- apply save delete rename export import
              elif [[ $words[3] == (import|export) ]]; then
                _files
              else
                compadd -- ${(f)"$(deepfield presets --names 2>/dev/null)"}
                _files -g '*.deepfield'
              fi ;;
            event)
              compadd -- ${(f)"$(deepfield events --all --names 2>/dev/null)"} ;;
            schedule) compadd -- status on off next ;;
            login) compadd -- status on off ;;
            completion) compadd -- zsh bash fish ;;
            help) compadd -- ${${(f)"$(deepfield help --commands 2>/dev/null)"}%%:*} ;;
            customize) compadd -- --section scene sky image system phone schedule ;;
            render)
              case $words[CURRENT-1] in
                --scene) compadd -- ${(f)"$(deepfield scenes --names 2>/dev/null)"} ;;
                --preset) compadd -- ${(f)"$(deepfield presets --names 2>/dev/null)"}; _files -g '*.deepfield' ;;
                --codec) compadd -- h264 hevc prores ;;
                *)
                  if [[ $PREFIX == -* ]]; then
                    compadd -- --scene --preset --defaults --config --smooth --no-events --demo --size --scale \
                      --time --duration --fps --speed --loop --codec --bitrate --open --quiet
                  else
                    compadd -- image video timelapse
                    _files
                  fi ;;
              esac ;;
          esac
        }

        compdef _deepfield deepfield
        """#

    static let bash = #"""
        _deepfield() {
          local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD-1]}
          if (( COMP_CWORD == 1 )); then
            COMPREPLY=($(compgen -W "$(deepfield help --commands 2>/dev/null | cut -d: -f1)" -- "$cur"))
            return
          fi
          case $prev in
            --scene) COMPREPLY=($(compgen -W "$(deepfield scenes --names 2>/dev/null)" -- "$cur")); return ;;
            --codec) COMPREPLY=($(compgen -W "h264 hevc prores" -- "$cur")); return ;;
          esac
          case ${COMP_WORDS[1]} in
            scene)
              if (( COMP_CWORD == 2 )); then
                COMPREPLY=($(compgen -W "random $(deepfield scenes --names 2>/dev/null)" -- "$cur"))
              else
                compopt -o nospace; COMPREPLY=($(compgen -S = -W "$(deepfield keys --all --names 2>/dev/null)" -- "$cur"))
              fi ;;
            set) compopt -o nospace; COMPREPLY=($(compgen -S = -W "$(deepfield keys --all --names 2>/dev/null)" -- "$cur")) ;;
            get|reset) COMPREPLY=($(compgen -W "$(deepfield keys --all --names 2>/dev/null)" -- "$cur")) ;;
            preset)
              if (( COMP_CWORD == 2 )); then COMPREPLY=($(compgen -W "apply save delete rename export import" -- "$cur"))
              else COMPREPLY=($(compgen -f -- "$cur")); fi ;;
            event) COMPREPLY=($(compgen -W "$(deepfield events --all --names 2>/dev/null)" -- "$cur")) ;;
            schedule) COMPREPLY=($(compgen -W "status on off next" -- "$cur")) ;;
            login) COMPREPLY=($(compgen -W "status on off" -- "$cur")) ;;
            completion) COMPREPLY=($(compgen -W "zsh bash fish" -- "$cur")) ;;
            render)
              if [[ $cur == -* ]]; then
                COMPREPLY=($(compgen -W "--scene --preset --defaults --config --smooth --no-events --demo --size --scale --time --duration --fps --speed --loop --codec --bitrate --open --quiet" -- "$cur"))
              else
                COMPREPLY=($(compgen -W "image video timelapse" -- "$cur") $(compgen -f -- "$cur"))
              fi ;;
          esac
        }
        complete -F _deepfield deepfield
        """#

    static let fish = #"""
        function __deepfield_cmds; deepfield help --commands 2>/dev/null | string replace ':' \t; end
        complete -c deepfield -f
        complete -c deepfield -n __fish_use_subcommand -a '(__deepfield_cmds)'
        complete -c deepfield -n '__fish_seen_subcommand_from scene' -a 'random (deepfield scenes --names 2>/dev/null)'
        complete -c deepfield -n '__fish_seen_subcommand_from get reset' -a '(deepfield keys --all --names 2>/dev/null)'
        complete -c deepfield -n '__fish_seen_subcommand_from set' -a '(deepfield keys --all --names 2>/dev/null | string replace -r \'$\' =)'
        complete -c deepfield -n '__fish_seen_subcommand_from preset' -a 'apply save delete rename export import (deepfield presets --names 2>/dev/null)'
        complete -c deepfield -n '__fish_seen_subcommand_from event' -a '(deepfield events --all --names 2>/dev/null)'
        complete -c deepfield -n '__fish_seen_subcommand_from schedule' -a 'status on off next'
        complete -c deepfield -n '__fish_seen_subcommand_from login' -a 'status on off'
        complete -c deepfield -n '__fish_seen_subcommand_from completion' -a 'zsh bash fish'
        complete -c deepfield -n '__fish_seen_subcommand_from render' -F -a 'image video timelapse'
        complete -c deepfield -n '__fish_seen_subcommand_from render keys presets' -l scene -x -a '(deepfield scenes --names 2>/dev/null)'
        """#
}
