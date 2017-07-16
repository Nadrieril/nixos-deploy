let
  common_conf = { config, pkgs, lib, name, nodes, ... }: {
    # The `name` module parameter refers to the node name (here machine1 or machine2)
    deployment.targetHost = "root@${name}";
    networking.hostName = name;
  };

in
{
  machine1 = { config, pkgs, lib, name, nodes, ... }: {
    imports = [ common_conf ];

    services.nginx = {
      enable = true;
      # The `nodes` module parameter contains all the nodes' computed configurations
      virtualhosts.machine2.locations."/".proxyPass = "http://${nodes.machine2.custom.ip}";
    };
  };

  machine2 = { config, pkgs, lib, name, nodes, ... }: {
    imports = [ common_conf ];

    deployment.buildHost = "build@machine1";

    custom.ip = "10.0.0.2";

    services.radicale.enable = true;
  };
}
