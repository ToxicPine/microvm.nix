{ config, lib, pkgs, ... }:
let
  self-lib = import ../../lib {
    inherit lib;
  };

  cfg = config.microvm;
  hostName = config.networking.hostName or "$HOSTNAME";
  kernelAtLeast = lib.versionAtLeast config.boot.kernelPackages.kernel.version;
in
{
  options.microvm = with lib; {
    guest.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to enable the microvm.nix guest module at all.
      '';
    };

    optimize.enable = lib.mkOption {
      description = ''
        Enables some optimizations by default to closure size and startup time:
          - defaults documentation to off
          - defaults to using systemd in initrd
          - use systemd-networkd
          - disables systemd-network-wait-online
          - disables NixOS system switching if the host store is not mounted

        This takes a few hundred MB off the closure size, including qemu,
        allowing for putting MicroVMs inside Docker containers.
      '';

      type = lib.types.bool;
      default = true;
    };

    cpu = mkOption {
      type = with types; nullOr str;
      default = null;
      description = ''
        What CPU to emulate, if any. If different from the host
        architecture, it will have a serious performance hit.

        ::: {.note}
        Only supported with qemu.
        :::
      '';
    };

    hypervisor = mkOption {
      type = types.enum self-lib.hypervisors;
      default = "qemu";
      description = ''
        Which hypervisor to use for this MicroVM

        Choose one of: ${lib.concatStringsSep ", " self-lib.hypervisors}
      '';
    };

    preStart = mkOption {
      description = "Commands to run before starting the hypervisor";
      default = "";
      type = types.lines;
    };

    extraArgsScript = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        A script to provide additional arguments for the hypervisor at runtime.

        The script must output a single line with arguments for the hypervisor.
      '';
    };

    socket = mkOption {
      description = "Hypervisor control socket path";
      default = "${hostName}.sock";
      defaultText = literalExpression ''"''${hostName}.sock"'';
      type = with types; nullOr str;
    };

    user = mkOption {
      description = "User to switch to when started as root";
      default = null;
      type = with types; nullOr str;
    };

    kernel = mkOption {
      description = "Kernel package to use for MicroVM runners. Better set `boot.kernelPackages` instead.";
      default = config.boot.kernelPackages.kernel;
      defaultText = literalExpression ''"''${config.boot.kernelPackages.kernel}"'';
      type = types.package;
    };

    initrdPath = mkOption {
      description = "Path to the initrd file in the initrd package";
      default = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
      defaultText = literalExpression ''"''${config.system.build.initialRamdisk}/''${config.system.boot.loader.initrdFile}"'';
      type = types.path;
    };

    vcpu = mkOption {
      description = "Number of virtual CPU cores";
      default = 1;
      type = types.ints.positive;
    };

    mem = mkOption {
      description = "Amount of RAM in megabytes";
      default = 512;
      type = types.ints.positive;
    };

    hugepageMem = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to use hugepages as memory backend.
        (Currently only respected if using cloud-hypervisor)
      '';
    };

    hotplugMem = mkOption {
      description = ''
        Amount of hotplug memory in megabytes.

        This describes the maximum amount of memory that can be dynamically added to the VM with virtio-mem.
      '';
      default = 0;
      type = types.ints.unsigned;
    };

    hotpluggedMem = mkOption {
      description = ''
        Amount of hotplugged memory in megabytes.

        This basically describes the amount of hotplug memory the VM starts with.
      '';
      default = config.microvm.hotplugMem;
      type = types.ints.unsigned;
    };

    balloon = mkOption {
      description = ''
        Whether to enable ballooning.

        By "inflating" or increasing the balloon the host can reduce the VMs
        memory amount and reclaim it for itself.
        When "deflating" or decreasing the balloon the host can give the memory
        back to the VM.

        virtio-mem is recommended over ballooning if supported by the hypervisor.
      '';
      default = false;
      type = types.bool;
    };

    initialBalloonMem = mkOption {
      description = ''
        Amount of initial balloon memory in megabytes.
      '';
      default = 0;
      type = types.ints.unsigned;
    };

    deflateOnOOM = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to enable automatic balloon deflation on out-of-memory.
      '';
    };


    forwardPorts = mkOption {
      type = types.listOf
        (types.submodule {
          options.from = mkOption {
            type = types.enum [ "host" "guest" ];
            default = "host";
            description =
              ''
                Controls the direction in which the ports are mapped:

                - <literal>"host"</literal> means traffic from the host ports
                is forwarded to the given guest port.

                - <literal>"guest"</literal> means traffic from the guest ports
                is forwarded to the given host port.
              '';
          };
          options.proto = mkOption {
            type = types.enum [ "tcp" "udp" ];
            default = "tcp";
            description = "The protocol to forward.";
          };
          options.host.address = mkOption {
            type = types.str;
            default = "";
            description = "The IPv4 address of the host.";
          };
          options.host.port = mkOption {
            type = types.port;
            description = "The host port to be mapped.";
          };
          options.guest.address = mkOption {
            type = types.str;
            default = "";
            description = "The IPv4 address on the guest VLAN.";
          };
          options.guest.port = mkOption {
            type = types.port;
            description = "The guest port to be mapped.";
          };
        });
      default = [];
      example = lib.literalExpression /* nix */ ''
        [ # forward local port 2222 -> 22, to ssh into the VM
          { from = "host"; host.port = 2222; guest.port = 22; }

          # forward local port 80 -> 10.0.2.10:80 in the VLAN
          { from = "guest";
            guest.address = "10.0.2.10"; guest.port = 80;
            host.address = "127.0.0.1"; host.port = 80;
          }
        ]
      '';
      description =
        ''
          When using the SLiRP user networking (default), this option allows to
          forward ports to/from the host/guest.

          ::: {.warning}
          If the NixOS firewall on the virtual machine is enabled, you
          also have to open the guest ports to enable the traffic
          between host and guest.
          :::

          ::: {.note}
          Currently QEMU supports only IPv4 forwarding.
          :::
        '';
    };

    volumes = mkOption {
      description = "Disk images";
      default = [];
      type = with types; listOf (submodule {
        options = {
          image = mkOption {
            type = str;
            description = "Path to disk image on the host";
          };
          serial = mkOption {
            type = nullOr str;
            default = null;
            description = "User-configured serial number for the disk";
          };
          direct = mkOption {
            type = bool;
            default = false;
            description = "Whether to set O_DIRECT on the disk.";
          };
          readOnly = mkOption {
            type = bool;
            default = false;
            description = "Turn off write access";
          };
          label = mkOption {
            type = nullOr str;
            default = null;
            description = "Label of the volume, if any. Only applicable if `autoCreate` is true; otherwise labeling of the volume must be done manually";
          };
          mountPoint = mkOption {
            type = nullOr path;
            description = "If and where to mount the volume inside the container";
          };
          size = mkOption {
            type = int;
            description = "Volume size (in MiB) if created automatically";
          };
          autoCreate = mkOption {
            type = bool;
            default = true;
            description = "Created image on host automatically before start?";
          };
          mkfsExtraArgs = mkOption {
            type = listOf str;
            default = [];
            description = "Set extra Filesystem creation parameters";
          };
          fsType = mkOption {
            type = str;
            default = "ext4";
            description = "Filesystem for automatic creation and mounting";
          };
          imageType = mkOption {
            type = types.enum [ "raw" "qcow2" "vhd" "vhdx" ];
            default = "raw";
            description = ''
              Format of the image (only passed to the hypervisor, does not change format of the image created if `autoCreate` is true).

              ::: {.note}
              Only supported with cloud-hypervisor.
              :::
            '';
          };
        };
      });
    };

    interfaces = mkOption {
      description = "Network interfaces";
      default = [];
      type = with types; listOf (submodule {
        options = {
          type = mkOption {
            type = enum [ "user" "tap" "macvtap" "bridge" ];
            description = ''
              Interface type
            '';
          };
          id = mkOption {
            type = str;
            description = ''
              Interface name on the host
            '';
          };
          macvtap.link = mkOption {
            type = str;
            description = ''
              Attach network interface to host interface for type = "macvlan"
            '';
          };
          macvtap.mode = mkOption {
            type = enum ["private" "vepa" "bridge" "passthru" "source"];
            description = ''
              The MACVLAN mode to use
            '';
          };
          bridge = mkOption {
            type = nullOr str;
            default = null;
            description = ''
              Attach network interface to host bridge interface for type = "bridge"
            '';
          };
          mac = mkOption {
            type = str;
            description = ''
              MAC address of the guest's network interface
            '';
          };
          tap.vhost = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Enable vhost-net for TAP interfaces.

              When enabled, packet processing is offloaded to the kernel's
              vhost-net module instead of QEMU userspace, significantly
              improving network throughput (~10 Gbps vs ~1.5 Gbps).

              Requires the vhost_net kernel module on the host.
            '';
          };
        };
      });
    };

    shares = mkOption {
      description = "Shared directory trees";
      default = [];
      type = with types; listOf (submodule ({ config, ... }: {
        options = {
          tag = mkOption {
            type = str;
            description = "Unique virtiofs daemon tag";
          };
          server = {
            socket = mkOption {
              type = nullOr str;
              default =
                if config.proto == "virtiofs"
                then "${hostName}-virtiofs-${config.tag}.sock"
                else null;
              description = ''
                Socket on which this share is served.

                Relative paths are resolved against the MicroVM's state
                directory.
              '';
            };
          };
          dax = {
            mode = mkOption {
              type = enum [ "never" "inode" "always" ];
              default = "never";
              description = ''
                DAX policy for this share. `never` copies file contents through
                the virtio queues. `inode` lets the server select DAX per file
                through lookup replies. `always` maps every regular file
                through the DAX window.

                Needs a hypervisor that supports DAX, a server that serves
                mappings, and a guest kernel built with `CONFIG_FUSE_DAX`.
                Hypervisors without it reject `inode` and `always` rather than
                silently ignoring them. Missing server or kernel support is not
                detectable here: mappings are declined and reads fall back to
                being copied.
              '';
            };
            window = mkOption {
              type = nullOr ints.positive;
              default = null;
              description = ''
                Size in bytes of the DAX window, for hypervisors that expect
                the VMM to choose one.

                Deliberately separate from {option}`dax.mode`, because who
                decides the size is not uniform: `alioth` takes it on its
                command line and requires it, while `crosvm` asks the server
                over `GET_SHMEM_CONFIG` and rejects a value set here. Folding
                the two together would make the size meaningless on half the
                hypervisors that support DAX.

                The window is a span of guest address space rather than
                allocated memory, so it can be sized generously.
              '';
              example = literalExpression "8 * 1024 * 1024 * 1024";
            };
          };
          source = mkOption {
            type = nullOr nonEmptyStr;
            default = null;
            description = ''
              Path to the shared directory tree on the host.

              Required for protocols the hypervisor serves itself, which is 9p
              and vfkit's built-in virtio-fs. A virtio-fs share reached over
              {option}`server.socket` needs no source here: whatever is behind
              that socket decides what it serves, and it need not be a
              directory at all.
            '';
          };
          securityModel = mkOption {
            type = enum [ "passthrough" "none" "mapped" "mapped-file" ];
            default = "none";
            description = "What security model to use for the shared directory";
          };
          mountPoint = mkOption {
            type = path;
            description = "Where to mount the share inside the container";
          };
          proto = mkOption {
            type = enum [ "9p" "virtiofs" ];
            description = "Protocol for this share";
            default = "9p";
          };
          readOnly = mkOption {
            type = bool;
            description = "Turn off write access";
            default = false;
          };
        };
      }));
    };

    devices = mkOption {
      description = "PCI/USB devices that are passed from the host to the MicroVM";
      default = [];
      example = literalExpression /* nix */ ''
        [ {
          bus = "pci";
          path = "0000:01:00.0";
        } {
          bus = "pci";
          path = "0000:01:01.0";
          deviceExtraArgs = "id=hostId,x-igd-opregion=on";
        } {
          # QEMU only
          bus = "usb";
          path = "vendorid=0xabcd,productid=0x0123";
        } ]
      '';
      type = with types; listOf (submodule {
        options = {
          bus = mkOption {
            type = enum [ "pci" "usb" ];
            description = ''
              Device is either on the `pci` or the `usb` bus
            '';
          };
          path = mkOption {
            type = str;
            description = ''
              Identification of the device on its bus
            '';
          };
          qemu = {
            id = mkOption {
              type = nullOr str;
              default = null;
              description = ''
                QEMU device identifier (optional)
              '';
            };
            bus = mkOption {
              type = nullOr str;
              default = null;
              description = ''
                QEMU bus to which this device is attached (optional)
              '';
            };
            deviceExtraArgs = mkOption {
              type =  nullOr str;
              default = null;
              description = ''
                Device additional arguments (optional)
              '';
            };
          };
        };
      });
    };

    vsock.cid = mkOption {
      default = null;
      # AF_VSOCK context IDs are unsigned 32-bit values. 0, 1 and 2 identify
      # the hypervisor, loopback and host respectively, while UINT32_MAX is
      # VMADDR_CID_ANY rather than a concrete guest address.
      type = with types; nullOr (ints.between 3 4294967294);
      description = ''
        Virtual machine AF_VSOCK context ID; setting it enables AF_VSOCK.
        Values 0, 1, 2 and 4294967295 are reserved.
      '';
    };

    registerWithMachined = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Register this MicroVM with systemd-machined on the host, enabling management via machinectl.

        When enabled, a registration script is generated in the runner package. The host module will call this
        script after the hypervisor starts. The VM is registered with class "vm" using the UUID from `machineId`
        (or a deterministic UUID derived from hostname).

        Supported machinectl commands:
        - `list`, `status`, `show` - VM visibility
        - `terminate`, `kill` - stop VM (will auto-restart if Restart=always)

        Note: `machinectl reboot` stops the VM but won't auto-restart it because systemd treats it as an
        intentional stop. Use `systemctl restart microvm@<name>` for restarts.
      '';
    };

    machineId = mkOption {
      type = with types; nullOr str;
      default =
        let
          hash = builtins.hashString "sha256" "microvm.nix:${hostName}";
          hs = offset: len:
            builtins.substring offset len hash;
        in builtins.concatStringsSep "-" [
          (hs 0 8)
          (hs 8 4)
          (hs 12 4)
          (hs 16 4)
          (hs 20 12)
        ];
      example = "a67472e5-570e-5c8a-b18c-ae3c77701050";
      description = ''
        UUID for this MicroVM, used for:
        - Registration with systemd-machined
        - SMBIOS system UUID (QEMU only)
        - Guest /etc/machine-id initialization when explicitly set

        If null, a deterministic UUIDv5 is generated at runtime from the hostname
        for machined registration and SMBIOS UUID.

        Format: 8-4-4-4-12 hex digits (standard UUID format).
      '';
    };

    kernelParams = mkOption {
      type = with types; listOf str;
      description = "Includes boot.kernelParams but doesn't end up in toplevel, thereby allowing references to toplevel";
    };

    storeOnDisk = mkOption {
      type = types.bool;
      default =
        config.microvm.storeOverlay == null
        && ! lib.any ({ source, ... }:
          source == "/nix/store"
        ) config.microvm.shares;
      defaultText = literalExpression ''
        config.microvm.storeOverlay == null
        && ! lib.any ({ source, ... }: source == "/nix/store") config.microvm.shares
      '';
      description = ''
        Whether to boot with the storeDisk, that is, unless the host's
        /nix/store is a microvm.share.

        Off by default with {option}`microvm.storeOverlay`, where the lower
        layer is named explicitly and supplied by a share or volume. Enable it
        to use the built store disk as that lower layer, in which case it is
        mounted at {option}`microvm.storeOverlay.lowerDir` and nothing else may
        provide that path.
      '';
    };

    registerClosure = lib.mkEnableOption ''
      Register system closure's store paths in Nix db.

      Off by default with {option}`microvm.storeOverlay`, where
      {option}`microvm.storeOverlay.lowerStore` is already authoritative for
      lower paths. Loading them into the guest's own database as well would
      leave two disagreeing records of the same store.
    '' // {
      default = config.microvm.guest.enable && config.microvm.storeOverlay == null;
      defaultText = literalExpression ''
        config.microvm.guest.enable && config.microvm.storeOverlay == null
      '';
    };

    storeOverlay = mkOption {
      default = null;
      example = literalExpression ''
        {
          lowerDir = "/lower-store/store";
          upperDir = "/data/upper-store";
          workDir = "/data/work";
          stateDir = "/data/nix-state";
          logDir = "/data/log";
          lowerStore = "unix:///lower-store/socket";
          checkMount = false;
        }
      '';
      description = ''
        Compose `/nix/store` as Nix's local-overlay store.

        OverlayFS is mounted at `/nix/store` from the configured
        directories, and the guest's Nix daemon is pointed at the matching
        `local-overlay://` store, so packages can be built inside the VM
        while sharing an immutable lower store with the host or with other
        VMs.

        Every path here must be provided by a share or a volume;
        this option only composes them. {option}`lowerDir` and
        {option}`lowerStore` must describe the same immutable store.
      '';
      type = with types; nullOr (submodule {
        options = {
          lowerDir = mkOption {
            type = path;
            description = ''
              Read-only lower layer of the overlay, holding the immutable
              store paths.
            '';
          };
          upperDir = mkOption {
            type = path;
            description = "Writable upper layer receiving paths built in this VM.";
          };
          workDir = mkOption {
            type = path;
            description = ''
              OverlayFS work directory: staging space for the copy-up of a
              file being modified.

              Required, because there is no default to fall back on and no
              safe one to invent: the kernel needs this on the same filesystem
              as {option}`upperDir`, and empty when the overlay is mounted.

              It holds no state worth preserving. It shares a volume with
              {option}`upperDir` because the kernel demands it, not because its
              contents outlive a boot.
            '';
          };
          stateDir = mkOption {
            type = path;
            description = ''
              Nix state directory, holding `''${stateDir}/db` - the upper
              layer's SQLite database - along with profiles and GC roots.

              Required rather than left to Nix, whose default of
              `/nix/var/nix` would put the database wherever `/nix` happens to
              live. That is usually a tmpfs here, which would discard every
              record of what this VM has built while leaving the paths
              themselves in the upper layer.
            '';
          };
          logDir = mkOption {
            type = nullOr path;
            default = null;
            description = ''
              Nix build log directory, or null to leave it to Nix, which
              defaults to `/nix/var/log/nix`.

              Optional because build logs are the one part of this that can be
              lost without the store disagreeing with itself.
            '';
          };
          lowerStore = mkOption {
            type = str;
            example = "unix:///lower-store/socket";
            description = ''
              Store URI serving metadata for the lower layer.

              This is the authoritative source of metadata for lower paths;
              it is not a second store that the guest writes to. It must
              describe exactly the store mounted at {option}`lowerDir`.
            '';
          };
          checkMount = mkOption {
            type = bool;
            default = true;
            description = ''
              Whether Nix should verify that `/nix/store` really is an
              overlay of the configured layers.

              Turn this off when the mount is composed in a way Nix cannot
              recognise, such as a lower layer served over virtio-fs.
            '';
          };
        };
      });
    };

    graphics = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable GUI support.

          The graphics backend is chosen by `microvm.graphics.backend`.
          The `gtk` and `cocoa` backends are intended for the interactive
          use-case and cannot be started through systemd jobs.
          The `headless` backend can be started through a systemd job
          as it does not open a host window.
        '';
      };

      crosvmPackage = mkOption {
        description = "crosvm package to use when running graphics (for cloud-hypervisor and crosvm)";
        default = pkgs.crosvm;
        defaultText = literalExpression ''"''${pkgs.crosvm}"'';
        type = types.package;
      };

      backend = mkOption {
        type = types.enum [ "gtk" "cocoa" "headless" ];
        default = if pkgs.stdenv.hostPlatform.isDarwin then "cocoa" else "gtk";
        defaultText = lib.literalExpression ''if pkgs.stdenv.hostPlatform.isDarwin then "cocoa" else "gtk"'';
        description = ''
          QEMU display backend to use when `graphics.enable` is true.

          Defaults to `cocoa` on Darwin hosts and `gtk` otherwise.
        '';
      };

      socket = mkOption {
        type = types.str;
        default = "${hostName}-gpu.sock";
        description = ''
          Path of vhost-user socket
        '';
      };
    };

    vmHostPackages = mkOption {
      description = "If set, overrides the default host package.";
      example = "nixpkgs.legacyPackages.aarch64-darwin.pkgs";
      type = types.pkgs;
      default = if cfg.cpu == null then pkgs else pkgs.buildPackages;
      defaultText = lib.literalExpression "if config.microvm.cpu == null then pkgs else pkgs.buildPackages";
    };

    qemu.machine = mkOption {
      type = types.str;
      description = ''
        QEMU machine model, eg. `microvm`, or `q35`

        Get a full list with `qemu-system-x86_64 -M help`

        This has a default declared with `lib.mkDefault` because it
        depends on ''${pkgs.system}.
      '';
    };

    qemu.machineOpts = mkOption {
      type = with types; nullOr (attrsOf str);
      default = null;
      description = "Overwrite the default machine model options.";
    };

    qemu.extraArgs = mkOption {
      type = with types; listOf str;
      default = [];
      description = "Extra arguments to pass to qemu.";
    };

    qemu.serialConsole = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to enable the virtual serial console on qemu.
      '';
    };

    qemu.pcieRootPorts = mkOption {
      description = ''
        A list of PCIe root ports that can be used for hot-plugging PCIe devices.
        This is particularly useful on the Q35 machine type, which does not support
        hot-plugging on the base PCIe root bus (pcie.0). Creating root ports allows
        attaching and detaching PCIe devices at runtime and can also be useful for
        devices that require their own dedicated PCIe slot with a fixed address, etc.
        For additional details see the QEMU PCI Express Guidelines:
        <https://gitlab.com/qemu-project/qemu/-/blob/master/docs/pcie.txt>
      '';
      default = [];
      example = literalExpression /* nix */ ''
        [ {
          bus = "pcie.0";
          id = "pci_port_0";
          chassis = 0;
        } ]
      '';
      type = with types; listOf (submodule {
        options = {
          id = mkOption {
            type = str;
            description = ''
              A unique identifier for this PCIe root port.
            '';
          };
          bus = mkOption {
            type = nullOr str;
            default = null;
            description = ''
              The PCIe bus on which the root port will be created.
            '';
          };
          chassis = mkOption {
            type = nullOr int;
            default = null;
            description = ''
              The chassis number associated with this PCIe root port.
            '';
          };
          slot = mkOption {
            type = nullOr str;
            default = null;
            description = ''
              PCIe slot number.
            '';
          };
          addr = mkOption {
            type = nullOr str;
            default = null;
            description = ''
              PCIe address on the parent bus.
            '';
          };
        };
      });
    };

    qemu.package = mkOption {
      description = "The QEMU package to use.";
      type = types.package;
      default = if cfg.cpu == null && cfg.vmHostPackages.stdenv.hostPlatform.isLinux then
        # If no CPU is requested and the host is Linux, use qemu with KVM support (hardware-accelerated)
        cfg.vmHostPackages.qemu_kvm
      else
        # Different CPU architectures like darwin or Non-Linux use the generic qemu package
        cfg.vmHostPackages.qemu;
      defaultText = lib.literalExpression ''
        if config.microvm.cpu == null && config.microvm.vmHostPackages.stdenv.hostPlatform.isLinux then
          # If no CPU is requested and the host is Linux, use qemu with KVM support (hardware-accelerated)
          config.microvm.vmHostPackages.qemu_kvm
        else
          # Different CPU architectures like darwin or Non-Linux use the generic qemu package
          config.microvm.vmHostPackages.qemu
      '';
    };

    alioth.package = mkOption {
      description = "The alioth package to use.";
      type = types.package;
      default = cfg.vmHostPackages.alioth;
      defaultText = lib.literalExpression "config.microvm.vmHostPackages.alioth";
    };

    cloud-hypervisor.platformOEMStrings = mkOption {
      type = with types; listOf str;
      default = [];
      description = ''
        Extra arguments to pass to cloud-hypervisor's --platform oem_strings=[] argument.

        All the oem strings will be concatenated with a comma (,) and wrapped in oem_string=[].

        Do not include oem_string= or the [] brackets in the value.

        The resulting string will be combined with any --platform options in
        `config.microvm.cloud-hypervisor.extraArgs` and passed as a single
        --platform option to cloud-hypervisor
      '';
      example = lib.literalExpression /* nix */ ''[ "io.systemd.credential:APIKEY=supersecret" ]'';
    };

    cloud-hypervisor.extraArgs = mkOption {
      type = with types; listOf str;
      default = [];
      description = "Extra arguments to pass to cloud-hypervisor.";
    };

    cloud-hypervisor.package = mkOption {
      description = "The cloud-hypervisor package to use.";
      type = types.package;
      default = if cfg.graphics.enable then
        cfg.vmHostPackages.cloud-hypervisor-graphics
      else
        cfg.vmHostPackages.cloud-hypervisor;
      defaultText = lib.literalExpression ''
        if config.microvm.graphics.enable then
          config.microvm.vmHostPackages.cloud-hypervisor-graphics
        else
          config.microvm.vmHostPackages.cloud-hypervisor
      '';
    };

    crosvm.extraArgs = mkOption {
      type = with types; listOf str;
      default = [];
      description = "Extra arguments to pass to crosvm.";
    };

    crosvm.pivotRoot = mkOption {
      type = with types; nullOr str;
      default = null;
      description = "A Hypervisor's sandbox directory";
    };

    crosvm.package = mkOption {
      description = "The crosvm package to use.";
      type = types.package;
      default = cfg.vmHostPackages.crosvm;
      defaultText = lib.literalExpression "config.microvm.vmHostPackages.crosvm";
    };

    firecracker.cpu = mkOption {
      type = with types; nullOr attrs;
      default = null;
      description = "Custom CPU template passed to firecracker.";
    };

    firecracker.driveIoEngine = mkOption {
      type = types.enum [ "Async" "Sync" ];
      default = "Async";
      description = "Type of IO engine to use for Firecracker drives (disks).";
    };

    firecracker.extraArgs = mkOption {
      type = with types; listOf str;
      default = [];
      description = "Extra arguments to pass to firecracker.";
    };

    firecracker.extraConfig = mkOption {
      type = types.submodule {
        freeformType =
          # vendored (pkgs.formats.json {}).type to avoid pkgs dependency and eval failure in search's
          with types;
          let
            baseType = oneOf [
              bool
              int
              float
              str
              path
              (attrsOf valueType)
              (listOf valueType)
            ];
            valueType = nullOr baseType // {
              description = "JSON value";
            };
          in
          valueType;
      };
      default = {};
      description = "Extra config to merge into Firecracker JSON configuration";
    };

    firecracker.package = mkOption {
      description = "The firecracker package to use.";
      type = types.package;
      default = cfg.vmHostPackages.firecracker;
      defaultText = lib.literalExpression "config.microvm.vmHostPackages.firecracker";
    };

    kvmtool.package = mkOption {
      description = "The kvmtool package to use.";
      type = types.package;
      default = cfg.vmHostPackages.kvmtool;
      defaultText = lib.literalExpression "config.microvm.vmHostPackages.kvmtool";
    };

    stratovirt.package = mkOption {
      description = "The stratovirt package to use.";
      type = types.package;
      default = cfg.vmHostPackages.stratovirt;
      defaultText = lib.literalExpression "config.microvm.vmHostPackages.stratovirt";
    };

    vfkit.extraArgs = mkOption {
      type = with types; listOf str;
      default = [];
      description = "Extra arguments to pass to vfkit.";
    };

    vfkit.logLevel = mkOption {
      type = with types; nullOr (enum ["debug" "info" "error"]);
      default = "info";
      description = "vfkit log level.";
    };

    vfkit.package = mkOption {
      description = "The vfkit package to use.";
      type = types.package;
      default = cfg.vmHostPackages.vfkit;
      defaultText = lib.literalExpression "config.microvm.vmHostPackages.vfkit";
    };

    vfkit.rosetta = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable Rosetta support for running x86_64 binaries in ARM64 Linux VMs.
          Only works on Apple Silicon (ARM) Macs.

          When enabled, the Rosetta virtiofs share will be automatically mounted
          and binfmt will be configured to use Rosetta for x86_64 binaries.
        '';
      };

      install = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Automatically install Rosetta if missing.
          If false and Rosetta is not installed, vfkit will fail to start.
        '';
      };

      ignoreIfMissing = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Continue execution even if Rosetta installation fails or is unavailable.
          Useful for configurations that should work on both ARM and Intel Macs.
        '';
      };
    };

    prettyProcnames = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Set a recognizable process name right before executing the Hyperisor.
      '';
    };

    runner = mkOption {
      description = "Generated Hypervisor runner for this NixOS";
      type = with types; attrsOf package;
    };

    declaredRunner = mkOption {
      description = "Generated Hypervisor declared by `config.microvm.hypervisor`";
      type = types.package;
      default = config.microvm.runner.${config.microvm.hypervisor};
      defaultText = literalExpression ''"config.microvm.runner.''${config.microvm.hypervisor}"'';
    };

    binScripts = mkOption {
      description = ''
        Script snippets that end up in the runner package's bin/ directory
      '';
      default = {};
      type = with types; attrsOf lines;
    };

    storeDiskType = mkOption {
      type = types.enum [ "squashfs" "erofs" ];
      description = ''
        Boot disk file system type: squashfs is smaller, erofs is supposed to be faster.

        Defaults to erofs, unless the NixOS hardened profile is detected.
      '';
    };

    storeDiskErofsFlags = mkOption {
      type = with types; listOf str;
      description = ''
        Flags to pass to mkfs.erofs

        `"-Ededupe"` is omitted by default because it forces single-threaded, slower builds.
        Add it back if you prefer smaller images over fast, multi-threaded builds.
      '';
      default =
        [ "-zlz4hc" ]
        ++
        lib.optional (kernelAtLeast "5.16") "-Eztailpacking"
        ++
        lib.optional (kernelAtLeast "6.1") "-Efragments";
      defaultText = lib.literalExpression ''
        [ "-zlz4hc" ]
          ++ lib.optional (kernelAtLeast "5.16") "-Eztailpacking"
          ++ lib.optional (kernelAtLeast "6.1") "-Efragments"
        '';
    };

    storeDiskSquashfsFlags = mkOption {
      type = with types; listOf str;
      description = "Flags to pass to gensquashfs";
      default = [ "-c" "zstd" "-j" "$NIX_BUILD_CORES" ];
    };

    systemSymlink = mkOption {
      type = types.bool;
      default = !config.microvm.storeOnDisk;
      description = ''
        Whether to inclcude a symlink of `config.system.build.toplevel` to `share/microvm/system`.
        This is required for commands like `microvm -l` to function but removes reference to the uncompressed store content when using a disk image for the nix store.
      '';
    };

    credentialFiles = mkOption {
      type = with types; attrsOf path;
      default = {};
      description = ''
        Key-value pairs of credential files that will be loaded into the vm using systemd's io.systemd.credential feature.
      '';
      example = literalExpression /* nix */ ''
        {
          SOPS_AGE_KEY = "/run/secrets/guest_microvm_age_key";
        }
      '';
    };
  };

  imports = [
    (lib.mkRemovedOptionModule ["microvm" "balloonMem"] "The balloonMem option has been removed and replaced by the boolean option balloon")
  ];

  config = lib.mkMerge [ {
    microvm.qemu.machine =
      lib.mkIf (lib.elem pkgs.stdenv.hostPlatform.system [ "x86_64-linux" ]) (
        lib.mkDefault "microvm"
      );
  } {
    microvm.qemu.machine =
      lib.mkIf (lib.elem pkgs.stdenv.hostPlatform.system [ "aarch64-linux" "aarch64-darwin" ]) (
        lib.mkDefault "virt"
      );
  } ];
}
