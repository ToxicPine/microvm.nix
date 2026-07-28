{ config, lib, ... }:

let
  inherit (config.microvm) storeDiskType storeOnDisk storeOverlay;

  inherit (import ../../lib {
    inherit lib;
  }) defaultFsType withDriveLetters;

  hostStore = builtins.head (
    builtins.filter ({ source, ... }:
      source == "/nix/store"
    ) config.microvm.shares
  );

  roStoreDisk =
    if storeOnDisk
    then
      if storeDiskType == "erofs"
      # erofs supports filesystem labels
      then "/dev/disk/by-label/nix-store"
      else "/dev/vda"
    else throw "No disk letter when /nix/store is not in disk";

  # Everything the overlay store is composed from. Shares and volumes are
  # responsible for providing these; we only compose them.
  storeOverlayPaths = lib.optionals (storeOverlay != null) [
    storeOverlay.lowerDir
    storeOverlay.upperDir
    storeOverlay.workDir
    storeOverlay.stateDir
    storeOverlay.logDir
  ];

  # Whether a mount at `mountPoint` supplies part of the overlay store, and so
  # has to be available before /nix/store can be assembled.
  providesStoreOverlay = mountPoint:
    lib.any (path:
      path == mountPoint || lib.hasPrefix "${mountPoint}/" path
    ) storeOverlayPaths;

  # OverlayFS refuses upper layers on filesystems without native xattr
  # support, which includes virtio-fs.
  upperIsVirtiofsShare = lib.any ({ mountPoint, proto, ... }:
    proto == "virtiofs" && (
      mountPoint == storeOverlay.upperDir
      || lib.hasPrefix "${mountPoint}/" storeOverlay.upperDir
    )
  ) config.microvm.shares;

in
lib.mkIf config.microvm.guest.enable {
  fileSystems = lib.mkMerge [ (
    # built-in read-only store without overlay
    lib.optionalAttrs (
      storeOnDisk &&
      storeOverlay == null
    ) {
      "/nix/store" = {
        device = roStoreDisk;
        fsType = storeDiskType;
        options = [ "x-systemd.after=systemd-modules-load.service" ];
        neededForBoot = true;
        noCheck = true;
      };
    }
  ) (
    # host store is mounted somewhere else,
    # bind-mount to the proper place
    lib.optionalAttrs (
      !storeOnDisk &&
      storeOverlay == null &&
      hostStore.mountPoint != "/nix/store"
    ) {
      "/nix/store" = {
        device = hostStore.mountPoint;
        fsType = hostStore.proto;
        options = [ "ro" "bind" ];
        neededForBoot = true;
      };
    }
  ) (
    # The store disk can supply the overlay's lower layer, mounted where
    # `lowerDir` says rather than at a location of our choosing.
    lib.optionalAttrs (
      storeOnDisk &&
      storeOverlay != null
    ) {
      "${storeOverlay.lowerDir}" = {
        device = roStoreDisk;
        fsType = storeDiskType;
        options = [ "ro" "x-systemd.after=systemd-modules-load.service" ];
        neededForBoot = true;
        noCheck = true;
      };
    }
  ) (
    # /nix/store as Nix's local-overlay store
    lib.optionalAttrs (storeOverlay != null) {
      "/nix/store" = {
        neededForBoot = true;
        overlay = {
          lowerdir = [ storeOverlay.lowerDir ];
          upperdir = storeOverlay.upperDir;
          workdir = storeOverlay.workDir;
        };
        options = lib.mkIf upperIsVirtiofsShare [ "userxattr" ];
      };
    }
  ) {
    # a tmpfs / by default. can be overwritten.
    "/" = lib.mkDefault {
      device = "rootfs";
      fsType = "tmpfs";
      options = [ "size=50%,mode=0755" ];
      neededForBoot = true;
    };
  } (
    # Volumes
    builtins.foldl' (result: { label, mountPoint, letter, fsType ? defaultFsType, ... }:
      result // lib.optionalAttrs (mountPoint != null) {
        "${mountPoint}" = {
          inherit fsType;
          # Prioritize identifying a device by label if provided. This
          # minimizes the risk of misidentifying a device.
          device = if label != null then
            "/dev/disk/by-label/${label}"
          else
            "/dev/vd${letter}";
        } // lib.optionalAttrs (providesStoreOverlay mountPoint) {
          neededForBoot = true;
        };
      }) {} (withDriveLetters config.microvm)
  ) (
    # 9p/virtiofs Shares
    builtins.foldl' (result: { mountPoint, tag, proto, source, dax, ... }: result // {
      "${mountPoint}" = {
        device = tag;
        fsType = proto;
        options = {
          # A DAX window is only used if the mount asks for it. In inode mode
          # the server selects files through lookup replies; always mode maps
          # every regular file. Never mode omits the option and reads through
          # the virtio queues.
          "virtiofs" = [ "defaults" "x-systemd.after=systemd-modules-load.service" ]
            ++ lib.optional (dax.mode != "never") "dax=${dax.mode}";
          "9p" = [ "trans=virtio" "version=9p2000.L" "msize=65536" "x-systemd.after=systemd-modules-load.service" ];
        }.${proto};
      } // lib.optionalAttrs (source == "/nix/store" || providesStoreOverlay mountPoint) {
        neededForBoot = true;
      };
    }) {} config.microvm.shares
  ) ];

  # Fix unmounting in qemu on shutdown for /nix/store
  systemd.mounts = lib.mkIf (config.boot.initrd.systemd.enable && !storeOnDisk && storeOverlay == null) [ {
    what = "store";
    where = "/nix/store";
    overrideStrategy = "asDropin";
    unitConfig.DefaultDependencies = false;
  } ];
}
