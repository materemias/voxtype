# NixOS module for VoxType
#
# This module provides system-level configuration for VoxType.
# For user-level configuration with full options, use the Home Manager module.
#
# Usage in your configuration.nix or flake:
#
#   imports = [ voxtype.nixosModules.default ];
#
#   programs.voxtype = {
#     enable = true;
#     package = voxtype.packages.${system}.vulkan;
#     typingBackend = "wtype";
#   };
#
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.voxtype;
in {
  options.programs.voxtype = {
    enable = lib.mkEnableOption "VoxType voice-to-text";

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        The VoxType package to install.
        This should be set to one of the voxtype flake packages.
      '';
      example = lib.literalExpression "voxtype.packages.\${system}.vulkan";
    };

    # Runtime dependency configuration
    typingBackend = lib.mkOption {
      type = lib.types.enum [ "wtype" "ydotool" "both" ];
      default = "wtype";
      description = ''
        Backend for simulating keyboard input:

        - wtype: Wayland virtual keyboard protocol (recommended for Wayland)
          Works with most Wayland compositors, best Unicode/emoji support.

        - ydotool: Uses uinput kernel module, works on both X11 and Wayland.
          Requires ydotoold daemon. May need 'input' group membership.

        - both: Install both backends, let VoxType choose based on session.
      '';
    };

    # Input group for evdev hotkey (with security warning)
    inputGroupUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "alice" "bob" ];
      description = ''
        Users to add to the 'input' group for evdev hotkey access.

        SECURITY WARNING: The 'input' group grants read access to ALL input
        devices, including keyboards. This means any process running as these
        users could potentially act as a keylogger. Only use this if:

        - You need the built-in evdev hotkey (most users should use compositor
          keybindings instead, which don't require special permissions)
        - You understand and accept the security implications
        - You're on a single-user system with trusted software

        Leave empty (default) if using compositor keybindings for push-to-talk.
      '';
    };

    # ydotool daemon management
    ydotool = {
      enableDaemon = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable the ydotoold systemd user service.
          Required when using ydotool as the typing backend.
          The daemon will start automatically with the graphical session.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Install VoxType and selected typing backends
    environment.systemPackages = [ cfg.package ]
      ++ lib.optional (cfg.typingBackend == "wtype" || cfg.typingBackend == "both") pkgs.wtype
      ++ lib.optional (cfg.typingBackend == "ydotool" || cfg.typingBackend == "both") pkgs.ydotool
      ++ [ pkgs.wl-clipboard ];  # Always useful for clipboard fallback

    # Enable uinput for ydotool (required for ydotool to work)
    hardware.uinput.enable = lib.mkIf
      (cfg.typingBackend == "ydotool" || cfg.typingBackend == "both" || cfg.ydotool.enableDaemon)
      true;

    # Add specified users to input group (with assertion for awareness)
    users.users = lib.mkIf (cfg.inputGroupUsers != [ ]) (
      lib.genAttrs cfg.inputGroupUsers (user: {
        extraGroups = [ "input" ];
      })
    );

    # Warn if input group is used
    warnings = lib.optional (cfg.inputGroupUsers != [ ]) ''
      VoxType: You have added users to the 'input' group via programs.voxtype.inputGroupUsers.
      This grants read access to ALL input devices (keyboards, mice, etc.) which has
      security implications. Ensure this is intentional. Consider using compositor
      keybindings instead, which don't require special permissions.
    '';

    # ydotool daemon as a systemd user service
    systemd.user.services.ydotoold = lib.mkIf cfg.ydotool.enableDaemon {
      description = "ydotool daemon for virtual input";
      documentation = [ "man:ydotool(1)" ];
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];

      serviceConfig = {
        ExecStart = "${pkgs.ydotool}/bin/ydotoold";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
