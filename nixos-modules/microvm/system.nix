{ pkgs, lib, config, utils, ... }:

let
  inherit (config.microvm) storeOverlay;

  # `lower-store` is itself a store URI nested inside a query parameter, so it
  # has to be percent-encoded or its own scheme and path separators are read as
  # part of the outer URI.
  percentEncode = lib.replaceStrings
    [ ":" "/" "?" "&" "=" "%" "#" "+" " " ]
    [ "%3A" "%2F" "%3F" "%26" "%3D" "%25" "%23" "%2B" "%20" ];

  # Nix's URI for the store composed in mounts.nix. The daemon has to be told
  # about the lower store explicitly: it is the authoritative source of
  # metadata for lower paths, which are not in the guest's own database.
  storeOverlayUri = "local-overlay://?" + lib.concatStringsSep "&" (
    [
      "lower-store=${percentEncode storeOverlay.lowerStore}"
      "upper-layer=${percentEncode storeOverlay.upperDir}"
      "state=${percentEncode storeOverlay.stateDir}"
      "check-mount=${lib.boolToString storeOverlay.checkMount}"
    ]
    # Omitted rather than defaulted, so Nix applies its own.
    ++ lib.optional (storeOverlay.logDir != null)
      "log=${percentEncode storeOverlay.logDir}"
  );
in
{
  config = lib.mkIf config.microvm.guest.enable {
    assertions = [
      {assertion = (storeOverlay != null) -> (!config.nix.optimise.automatic && !config.nix.settings.auto-optimise-store);
       message = ''
         `nix.optimise.automatic` and `nix.settings.auto-optimise-store` do not work with `microvm.storeOverlay`.
       '';}
      {assertion = (storeOverlay != null) -> (storeOverlay.lowerDir != "/nix/store");
       message = ''
         `microvm.storeOverlay.lowerDir` cannot be `/nix/store`, which is the
         overlay's own mount point.
       '';}
      {assertion =
         (storeOverlay != null && config.microvm.storeOnDisk)
         -> ! lib.any (mountPoint: mountPoint == storeOverlay.lowerDir) (
              map ({ mountPoint, ... }: mountPoint) config.microvm.shares
              ++ builtins.filter (m: m != null) (
                   map ({ mountPoint, ... }: mountPoint) config.microvm.volumes
                 )
            );
       message = ''
         `microvm.storeOverlay.lowerDir` (${lib.optionalString (storeOverlay != null) storeOverlay.lowerDir}) is
         provided both by the built store disk (`microvm.storeOnDisk`) and by a
         share or volume. Pick one.
       '';}];


    boot.loader.grub.enable = false;
    # boot.initrd.systemd.enable = lib.mkDefault true;
    boot.initrd.kernelModules = [
      "virtio_mmio"
      "virtio_pci"
      "virtio_blk"
      "9pnet_virtio"
      "9p"
      "virtiofs"
    ] ++ lib.optionals (
      pkgs.stdenv.targetPlatform.system == "x86_64-linux" &&
      config.microvm.hypervisor == "firecracker"
    ) [
      # Keyboard controller that can receive CtrlAltDel
      "i8042"
    ] ++ lib.optionals (storeOverlay != null) [
      "overlay"
    ];

    microvm.kernelParams = let
      # When a store disk is used, we can drop references to the packed contents as the squashfs/erofs contains all paths.
      toplevel = if config.microvm.storeOnDisk then
        builtins.unsafeDiscardStringContext config.system.build.toplevel
      else
        config.system.build.toplevel;
    in config.boot.kernelParams ++ [
      "init=${toplevel}/init"
    ];

    # modules that consume boot time but have rare use-cases
    boot.blacklistedKernelModules = [
      "rfkill" "intel_pstate"
    ] ++ lib.optional (!config.microvm.graphics.enable) "drm";

    # `local-overlay-store` is still experimental, so it has to be enabled for
    # the URI to be accepted at all.
    nix.settings = lib.mkIf (storeOverlay != null) {
      extra-experimental-features = [ "local-overlay-store" ];
    };

    environment.variables.NIX_REMOTE = lib.mkIf (storeOverlay != null) "daemon";

    systemd =
      let
        # nix-daemon works only with a writable /nix/store
        enableNixDaemon = storeOverlay != null;
      in {
        services.nix-daemon.enable = lib.mkDefault enableNixDaemon;
        sockets.nix-daemon.enable = lib.mkDefault enableNixDaemon;

        # Only the daemon is given the overlay store. Putting it in nix.conf
        # instead would apply it to clients too, and they would each open the
        # store directly rather than going through the daemon that owns it.
        services.nix-daemon.serviceConfig.ExecStart = lib.mkIf enableNixDaemon (
          lib.mkForce [
            ""
            (utils.escapeSystemdExecArgs [
              "@${config.nix.package}/bin/nix-daemon"
              "nix-daemon"
              "--daemon"
              "--store"
              storeOverlayUri
            ])
          ]
        );

        # consumes a lot of boot time
        services.mount-pstore.enable = false;

        # just fails in the usual usage of microvm.nix
        generators = { systemd-gpt-auto-generator = "/dev/null"; };
      };

    # Set /etc/machine-id from machineId if provided
    # This ensures the guest machine-id matches the UUID passed to machined and SMBIOS
    environment.etc."machine-id" = lib.mkIf (config.microvm.machineId != null) {
      text = lib.replaceString "-" "" config.microvm.machineId + "\n";
    };
    # Generate hostId from machine-id like systemd would do
    networking.hostId = lib.mkIf (config.microvm.machineId != null) (lib.mkDefault (
      builtins.substring 0 8 config.microvm.machineId
    ));
  };
}
