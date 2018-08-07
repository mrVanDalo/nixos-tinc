{ config, lib, pkgs, ... }:

with lib;

let

  # todo move this to a lib

  assertWithMessage = test: message: value:
    if( test )
    then
      value
    else
      throw message;

  # Example:
  #   wrapNullable null -> []
  #   wrapNullable 1    -> [ 1 ]
  wrapNullable = nullOrElem:
    if ( nullOrElem != null )
    then
      [ nullOrElem ]
    else
      [];


  # module starts here!

  cfg = config.services.custom.tinc;

  hostsElement = {
    options = {
      realAddress = mkOption {
        type        = with types; listOf str;
        default     = [];
        description = ''
          Realworld Addresses of the Host, DNS is also possible.
          This Address is used in the 'connectTo' parameter.
        '';
      };
      publicKey = mkOption {
        type        = types.str;
        description = ''
          The publi keys  Ed25519 and RSA as String (not as the path)

          Example :
            nix-shell -p tinc_pre --run "tinc generate-keys 4096"
            cat *.pub
        '';
      };
      tincIp = mkOption {
        type        = with types; nullOr str;
        default     = null;
        description = ''
          Ip of the Host in the VPN Mesh

          Example: 10.1.2.3
        '';
      };
      tincSubnet = mkOption {
        type        = with types; nullOr str;
        default     = null;
        description = ''
          Subnet of Host in the VPN Mesh (not to confuse with networkSubnet)
          (will be merged with the networkSubnet, own subnet will be skipped)
          This is useful to connect subnets over tinc.

          Example : 10.1.2.0/24
        '';
      };
      extraConfig = mkOption {
        type        = with types; nullOr str;
        default     = null;
        description = ''
          Additional config which is not coverd by other parameters.
          See : https://www.tinc-vpn.org/documentation-1.1/Host-configuration-variables.html
        '';
      };
    };
  };

  networkElement = {
    options = {
      enable = mkEnableOption "enable this tinc network";
      debugLevel = mkOption {
        default = 0;
        type = types.addCheck types.int (l: l >= 0 && l <= 5);
        description = ''
          The amount of debugging information to add to the log. 0 means little
          logging while 5 is the most logging. <command>man tincd</command> for
          more details.
        '';
      };
      package = mkOption {
        type = types.package;
        default = pkgs.tinc_pre;
        defaultText = "pkgs.tinc_pre";
        description = ''
          Package to use for the tinc daemon's binary.
        '';
      };
      interfaceType = mkOption {
        default     = "tap";
        type        = types.enum [ "tun" "tap" ];
        description = ''
          Type of virtual interface used for the network connection
        '';
      };
      privateRsaKeyFile = mkOption {
        type        = types.path;
        description = ''
          Private key to use for transport encryption
        '';
      };
      privateEd25519KeyFile = mkOption {
        type        = types.path;
        description = ''
          Private key to use for transport encryption
        '';
      };
      name = mkOption {
        type        = types.str;
        default     = config.networking.hostName;
        description = ''
          Name of the host known to the tinc network

          This parameter needs to be a key in the hosts parameter,
          we use it to determin the configuration from there.
        '';
      };
      port = mkOption {
        type        = types.int ;
        default     = 655;
        description = ''
          Port to bind tinc service to
        '';
      };
      connectTo = mkOption {
        type        = with types; listOf str;
        default     = [];
        description = ''
          Hosts to connect to create the mesh.
        '';
      };
      hosts = mkOption {
        type        = with types; attrsOf (submodule hostsElement);
        description = ''
          Known hosts in the network.
        '';
      };
      networkSubnet = mkOption {
        type        = with types; nullOr str;
        default     = null;
        description = ''
          Network subnet what is behind this interface
          (will be merged with the hosts.tincSubnet)

          Example : 10.1.0.0/16
        '';
      };
      extraConfig = mkOption {
        type        = with types; nullOr str;
        default     = null;
        description = ''
          Additional config which is not coverd by other parameters.
          See : https://www.tinc-vpn.org/documentation-1.1/Host-configuration-variables.html
        '';
      };
    };
  };

in {

  options.services.custom.tinc = mkOption {
    type        = types.attrsOf (types.submodule networkElement);
    description = ''
      A powerfull VPN Mesh.
    '';
  };

  config = let

      activeNetworks = flip filterAttrs cfg (name: network: network.enable );
      activeNetworkAttributes = attrsToAttr: mapAttrs' attrsToAttr activeNetworks;
      activeNetworkList       = attrsToList: mapAttrsToList attrsToList activeNetworks;
      find = getAttrFromPath;

      getActiveHostParameter = key: networkData:
        getAttrFromPath [ key ] (flip find networkData.hosts [ networkData.name ] );

      # program shortcuts
      # -----------------
      iproute  = "${pkgs.iproute}/sbin/ip";
      ifconfig = "${pkgs.nettools}/bin/ifconfig";
      tunctl   = "${pkgs.tunctl}/bin/tunctl";
      wc       = "${pkgs.coreutils}/bin/wc";

    in {


    # create network interfaces
    # -------------------------
    networking.interfaces = activeNetworkAttributes (network: data:
      nameValuePair "tinc.${network}" {
        virtual     = true;
        virtualType = "${data.interfaceType}";
      }
    );


    # create users for services
    # -------------------------
    users.extraUsers = activeNetworkAttributes (network: _:
      nameValuePair "tinc.${network}" {
        description = "Tinc daemon user for ${network}";
        isSystemUser = true;
      }
    );

    boot.kernel.sysctl = let
      ipv4 = activeNetworkAttributes (network: _:
        nameValuePair "net.ipv4.conf.tinc/${network}.forwarding" true
      );
      ipv6 = activeNetworkAttributes (network: _:
        nameValuePair "net.ipv6.conf.tinc/${network}.forwarding" true
      );
    in
      ipv4 // ipv6;

    # create the services
    # -------------------
    systemd.services = activeNetworkAttributes (network: data:
      nameValuePair "tinc.${network}" {
        description = "Tinc Daemon - ${network}";
        wantedBy    = [ "multi-user.target" ];
        after       = [ "network.target" ];
        path        = [ data.package ];
        # todo : filter active hosts only for the current network
        restartTriggers =
        let
          activeHostFiles = flip mapAttrsToList data.hosts (host: _: "tinc/${network}/hosts/${host}");
        in [
          config.environment.etc."tinc/${network}/tinc-up".source
          config.environment.etc."tinc/${network}/tinc-down".source
          config.environment.etc."tinc/${network}/tinc.conf".source
        ] ++ (flip map activeHostFiles (hostFile: config.environment.etc."${hostFile}".source));
        serviceConfig = {
          Type       = "simple";
          Restart    = "always";
          RestartSec = "3";
          ExecStart  = ''
            ${data.package}/bin/tincd -D \
              -U tinc.${network} \
              -n ${network} \
              --pidfile /run/tinc.${network}.pid \
              -d ${toString data.debugLevel}
          '';
        };
        preStart = ''
          mkdir -p              /etc/tinc/${network}/{hosts,invitations}
          chown tinc.${network} /etc/tinc/${network}/{hosts,invitations}
        '';
      }
    );


    # create tinc clients
    # -------------------
    environment.systemPackages = let
      cli-wrappers = pkgs.stdenv.mkDerivation {
        name         = "tinc-cli-wrappers";
        buildInputs  = [ pkgs.makeWrapper ];
        buildCommand = let
            clientCreatorScript = concatStringsSep "\n" (activeNetworkList (network: data: ''
                makeWrapper ${data.package}/bin/tinc "$out/bin/tinc.${network}" \
                  --add-flags "--pidfile=/run/tinc.${network}.pid" \
                  --add-flags "--config=/etc/tinc/${network}"
                ''));
          in ''
            mkdir -p $out/bin
            ${clientCreatorScript}
          '';
      };
    in [ cli-wrappers ];


    # Open firewall for tinc connection service
    # -----------------------------------------
    networking.firewall.allowedUDPPorts = mkMerge (flip mapAttrsToList activeNetworks (_: data: [ data.port ] ));
    networking.firewall.allowedTCPPorts = mkMerge (flip mapAttrsToList activeNetworks (_: data: [ data.port ] ));


    # add hosts to /etc/hosts file
    # ----------------------------
    networking.extraHosts = foldl (a: b: a + b) "\n"
    (flatten
      (flip mapAttrsToList activeNetworks (name: network:
        (flip mapAttrsToList network.hosts (hostName: hostConfig: ''
          ${hostConfig.tincIp} ${hostName}.${name}
        ''
        ))
      ))
    );


    # assertions
    # ----------
    assertions =
      let
        nameIsInHosts = activeNetworkList (network: data: {
          assertion = data.hosts ? "${data.name}" ;
          message   = "hostname ${data.name} in network ${network} is not defined in its hosts attribute set";
        });
        connectToExists = flatten (activeNetworkList (network: data: flip map data.connectTo (connectTo: {
          assertion = data.hosts ? "${connectTo}" ;
          message   = ''
            hostname ${data.name} in network ${network} is not defined in its hosts attribute set
            but must be because it is listed in ${network}.${data.name}.connectTo
          '';
        })));
    in nameIsInHosts ++ connectToExists ;


    # create /etc/tinc file structure
    # -------------------------------
    environment.etc = let


      hostFiles = fold (a: b: a // b) { }
        (activeNetworkList (network: data: flip mapAttrs' data.hosts (host: hostConfig:
          nameValuePair "tinc/${network}/hosts/${host}" {
            mode = "0644";
            user = "tinc.${network}";
            text =
              let
                subnets = concatMapStrings (subnet: "Subnet = ${subnet}\n")
                  ([ hostConfig.tincIp ] ++ (wrapNullable hostConfig.tincSubnet));
                addresses = concatMapStrings (name: "Address = ${name} ${toString data.port}\n");
                extraConfig = if ( hostConfig.extraConfig != null ) then ''
                  # Extra Config - Start
                  ${hostConfig.extraConfig}
                  # Extra Config - End
                '' else "";
              in ''
                ${addresses hostConfig.realAddress}
                ${subnets}
                # Port   = ${toString data.port}
                ${extraConfig}
                ${hostConfig.publicKey}
              '';
          }
        )));


      tincConfig = activeNetworkAttributes (network: data:
        nameValuePair "tinc/${network}/tinc.conf" {
          mode = "0444";
          text = let
            tincConnect = concatMapStrings (name: "ConnectTo = ${name}\n");
            extraConfig = if ( data.extraConfig != null ) then ''
              # Extra Config - Start
              ${data.extraConfig}
              # Extra Config - End
            '' else "";
          in ''
            Name                  = ${data.name}
            DeviceType            = ${data.interfaceType}
            Interface             = tinc.${network}
            Ed25519PrivateKeyFile = ${data.privateEd25519KeyFile}
            PrivateKeyFile        = ${data.privateRsaKeyFile}
            Port                  = ${toString data.port}
            ${tincConnect data.connectTo}
            ${extraConfig}
          '';
        }
      );

      tincUp = activeNetworkAttributes (name: network:
        nameValuePair "tinc/${name}/tinc-up" {
          source =
            let
              # todo : remove current network
              allOtherHosts = flip filterAttrs network.hosts (host: _:
                host != network.name
              );
              hostSubnets = (flatten (flip mapAttrsToList allOtherHosts (host: hostConfig:
                wrapNullable hostConfig.tincSubnet
              )));
              networkSubnet = wrapNullable network.networkSubnet;

              allSubnets = networkSubnet ++ hostSubnets ;
              addSubnetCommands = flip map allSubnets (subnet:
                "${iproute} -4 route add ${subnet} dev $INTERFACE"
              );

            in assertWithMessage ( builtins.length allSubnets > 0 )
              ''tinc."${name}" missing tincSubnet or networkSubnet''
              (pkgs.writeScript "tinc-up-${name}" ''
                #!${pkgs.stdenv.shell}
                ${iproute} link set $INTERFACE up
                ${iproute} -4 addr  add ${getActiveHostParameter "tincIp" network} dev $INTERFACE
                ${concatStringsSep "\n" addSubnetCommands}
              '');
          }
        );

      tincDown = activeNetworkAttributes (name: network:
        nameValuePair "tinc/${name}/tinc-down" {
          source = pkgs.writeScript "tinc-down-${name}" ''
            #!${pkgs.stdenv.shell}

            /run/wrappers/bin/sudo ${ifconfig} $INTERFACE down

            if [[ `${iproute} a show $INTERFACE | ${wc} -l` -eq 0 ]]
            then
              echo "$INTERFACE is gone"
            else
              echo "$INTERFACE still exists remove using tunctl"
              /run/wrappers/bin/sudo ${iproute} link set dev $INTERFACE down
              /run/wrappers/bin/sudo ${tunctl} -d $INTERFACE
            fi
          '';
          }
        );

    in tincUp // tincDown // tincConfig // hostFiles;


    # sudo rules for tinc-up/tinc-down
    # --------------------------------
    security.sudo.extraRules =
      (flip mapAttrsToList activeNetworks (name: network:
        {
          users    = [ "tinc.${name}" ];
          commands = [
            {
              command  = "${ifconfig}";
              options  = [ "NOPASSWD" ];
            }
            {
              command  = "${iproute}";
              options  = [ "NOPASSWD" ];
            }
            {
              command  = "${tunctl}";
              options  = [ "NOPASSWD" ];
            }
          ];
        }
      ));


  };
}

