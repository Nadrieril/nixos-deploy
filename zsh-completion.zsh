#compdef nixos-deploy

local context state state_descr line
typeset -A opt_args
local -a args commands hosts

args=(
  '--fast[Do not build nix]'
  '(-f --hosts-file)'{-f,--hosts-file}'[Choose the hosts file]:hosts file:_files'
  '*'{-h,--host}'[Selects a host]:host name:->host'
  '1:command:->cmd'
)

_arguments $args

case $state in
  cmd)
    commands=($(nixos-deploy __complete_commands))
    _describe 'command' commands
    ;;

  host)
    hosts_file=$opt_args[-f]
    if [ -z "$hosts_file" ]; then
      hosts=($(nixos-deploy __complete_hosts))
    else
      hosts=($(nixos-deploy -f "$hosts_file" __complete_hosts))
    fi
    _describe 'host' hosts
    ;;
esac
