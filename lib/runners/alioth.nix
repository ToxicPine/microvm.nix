{ pkgs
, microvmConfig
, linuxTarget
, ...
}:

let
  inherit (pkgs) lib;

  aliothPkg = microvmConfig.alioth.package;

  inherit (microvmConfig)
    user
    vcpu mem balloon initialBalloonMem hotplugMem hotpluggedMem interfaces volumes shares devices vsock
    kernel initrdPath
    storeDisk storeOnDisk credentialFiles;
in {
  command =
    if user != null
    then throw "alioth will not change user"
    else if balloon
    then throw "balloon not implemented for alioth"
    else if initialBalloonMem != 0
    then throw "initialBalloonMem not implemented for alioth"
    else if hotplugMem != 0
    then throw "alioth does not support hotplugMem"
    else if hotpluggedMem != 0
    then throw "alioth does not support hotpluggedMem"
    else if credentialFiles != {}
    then throw "alioth does not support credentialFiles"
    else builtins.concatStringsSep " " (
      [
        "${aliothPkg}/bin/alioth" "run"
        "--memory" "size=${toString mem}M,backend=memfd"
        "--num-cpu" (toString vcpu)
        "-k" (lib.escapeShellArg "${kernel}/${linuxTarget}")
        "-i" initrdPath
        "-c" (lib.escapeShellArg "console=ttyS0 reboot=k panic=1 ${toString microvmConfig.kernelParams}")
        "--entropy"
      ]
      ++
      lib.optionals storeOnDisk [
        "--blk" (lib.escapeShellArg "file,path=${storeDisk},readonly=true")
      ]
      ++
      builtins.concatMap ({ image, serial, direct, readOnly, ... }:
        lib.warnIf (serial != null) ''
          Volume serial is not supported for alioth
        ''
        lib.warnIf direct ''
          Volume direct IO is not supported for alioth
        ''
          [
            "--blk"
            (lib.escapeShellArg "file,path=${image},readonly=${
              lib.boolToString readOnly
            }")
          ]
      ) volumes
      ++
      builtins.concatMap ({ proto, server, tag, dax, ... }:
        if proto == "virtiofs"
        then
          # alioth sizes the window itself, so it has to be told.
          lib.throwIf (dax.mode != "never" && dax.window == null)
            "alioth needs dax.window when dax.mode is not never"
          [
            "--fs" (lib.escapeShellArg (
              "vu,socket=${server.socket},tag=${tag}"
              + lib.optionalString (dax.mode != "never") ",dax_window=${toString dax.window}"
            ))
          ] else throw "9p shares not implemented for alioth"
      ) shares
      ++
      builtins.concatMap ({ type, id, mac, ... }:
        if type == "tap"
        then [
          "--net" (lib.escapeShellArg "if_name=${id},mac=${mac},queue_pairs=${toString vcpu},mtu=1500")
        ]
        else throw "interface type ${type} is not supported by alioth"
      ) interfaces
      ++
      map ({ ... }:
        throw "PCI/USB passthrough is not supported on alioth"
      ) devices
      ++
      lib.optionals (vsock.cid != null) [
        "--vsock" "vhost,cid=${toString vsock.cid}"
      ]
    );

  # TODO:
  canShutdown = false;
}
