# Home Manager module for VoxType
#
# Usage in your home.nix or flake-based home-manager config:
#
#   imports = [ voxtype.homeManagerModules.default ];
#
#   programs.voxtype = {
#     enable = true;
#     package = voxtype.packages.${system}.vulkan;  # or .default for CPU
#     model.name = "base.en";
#     hotkey.enable = true;
#     service.enable = true;
#   };
#
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.voxtype;
  tomlFormat = pkgs.formats.toml { };
  modelDefs = import ./models.nix;

  # Fetch model from HuggingFace if using declarative model management
  fetchedModel = lib.optionalAttrs (cfg.model.name != null) (
    let modelDef = modelDefs.${cfg.model.name}; in
    pkgs.fetchurl {
      url = modelDef.url;
      hash = modelDef.hash;
    }
  );

  # Resolve the model path (fetched or user-provided)
  resolvedModelPath =
    if cfg.model.path != null then cfg.model.path
    else if cfg.model.name != null then fetchedModel
    else throw "programs.voxtype: either model.name or model.path must be set";

  # Runtime dependencies to wrap into PATH
  runtimeDeps = with pkgs; [
    # Wayland typing
    wtype
    wl-clipboard
    # Alternative typing backend (works on X11 and Wayland)
    ydotool
    # X11 fallback
    xdotool
    xclip
    # Common utilities
    libnotify
    pciutils
  ];

  # Wrap the package with runtime dependencies
  wrappedPackage = pkgs.symlinkJoin {
    name = "voxtype-wrapped-${cfg.package.version or "unknown"}";
    paths = [ cfg.package ];
    buildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/voxtype \
        --prefix PATH : ${lib.makeBinPath runtimeDeps}
    '';
  };

  # Build the config TOML from options
  configFile = tomlFormat.generate "voxtype-config.toml" (
    lib.recursiveUpdate {
      state_file = cfg.stateFile;

      hotkey = {
        enabled = cfg.hotkey.enable;
        key = cfg.hotkey.key;
        modifiers = cfg.hotkey.modifiers;
        mode = cfg.hotkey.mode;
      };

      audio = {
        device = cfg.audio.device;
        sample_rate = cfg.audio.sampleRate;
        max_duration_secs = cfg.audio.maxDurationSecs;
      } // lib.optionalAttrs cfg.audio.feedback.enable {
        feedback = {
          enabled = true;
          theme = cfg.audio.feedback.theme;
          volume = cfg.audio.feedback.volume;
        };
      };

      whisper = {
        model = toString resolvedModelPath;
        language = cfg.whisper.language;
        translate = cfg.whisper.translate;
        on_demand_loading = cfg.whisper.onDemandLoading;
      } // lib.optionalAttrs (cfg.whisper.threads != null) {
        threads = cfg.whisper.threads;
      };

      output = {
        mode = cfg.output.mode;
        fallback_to_clipboard = cfg.output.fallbackToClipboard;
        type_delay_ms = cfg.output.typeDelayMs;
        notification = {
          on_recording_start = cfg.output.notification.onRecordingStart;
          on_recording_stop = cfg.output.notification.onRecordingStop;
          on_transcription = cfg.output.notification.onTranscription;
        };
      } // lib.optionalAttrs (cfg.output.postProcess.command != null) {
        post_process = {
          command = cfg.output.postProcess.command;
          timeout_ms = cfg.output.postProcess.timeoutMs;
        };
      };

      status = {
        icon_theme = cfg.status.iconTheme;
      } // lib.optionalAttrs (cfg.status.icons != { }) {
        icons = cfg.status.icons;
      };
    } cfg.settings
  );

in {
  options.programs.voxtype = {
    enable = lib.mkEnableOption "VoxType push-to-talk voice-to-text";

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        The VoxType package to use. Use the flake's packages.default for CPU
        or packages.vulkan for GPU acceleration.
      '';
      example = lib.literalExpression "voxtype.packages.\${system}.vulkan";
    };

    # Model configuration
    model = {
      name = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum (builtins.attrNames modelDefs));
        default = "base.en";
        description = ''
          Whisper model to use. The model will be downloaded from HuggingFace
          and stored in the Nix store. Set to null if using model.path instead.

          Available models:
          - tiny, tiny.en (75 MB) - Fastest, lowest quality
          - base, base.en (142 MB) - Good balance for most users
          - small, small.en (466 MB) - Better accuracy
          - medium, medium.en (1.5 GB) - High accuracy
          - large-v3 (3.1 GB) - Best accuracy
          - large-v3-turbo (1.6 GB) - Fast + high accuracy

          The .en variants are English-only but faster and more accurate for English.
        '';
      };

      path = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a custom whisper model file. Use this instead of model.name
          if you want to manage the model yourself or use a custom model.
        '';
        example = "/home/user/.local/share/voxtype/models/ggml-custom.bin";
      };
    };

    # Hotkey configuration
    hotkey = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable the built-in evdev hotkey.

          RECOMMENDED: Most users should leave this DISABLED and use compositor
          keybindings instead (Hyprland bind/bindr, Sway bindsym, River riverctl).
          Compositor bindings are more secure and work without special permissions.

          Only enable this if you:
          - Are on X11 without a compositor that supports key-release events
          - Need a dedicated key like ScrollLock that your compositor can't bind
          - Understand the security implications of the 'input' group

          SECURITY WARNING: This requires membership in the 'input' group, which
          grants read access to ALL input devices including keyboards. This means
          any process running as your user could potentially act as a keylogger.
          Only add yourself to the 'input' group if you understand and accept this
          risk. On a single-user system with trusted software this is generally fine,
          but on shared systems or with untrusted software it's a security concern.
        '';
      };

      key = lib.mkOption {
        type = lib.types.str;
        default = "SCROLLLOCK";
        description = ''
          Key to hold for push-to-talk (when hotkey.enable is true).
          Common choices: SCROLLLOCK, PAUSE, RIGHTALT, F13-F24.
          Use `evtest` to find key names for your keyboard.
        '';
        example = "F13";
      };

      modifiers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Modifier keys that must also be held.";
        example = [ "LEFTCTRL" "LEFTALT" ];
      };

      mode = lib.mkOption {
        type = lib.types.enum [ "push_to_talk" "toggle" ];
        default = "push_to_talk";
        description = ''
          Activation mode:
          - push_to_talk: Hold hotkey to record, release to transcribe
          - toggle: Press once to start recording, press again to stop
        '';
      };
    };

    # Audio configuration
    audio = {
      device = lib.mkOption {
        type = lib.types.str;
        default = "default";
        description = ''
          Audio input device. Use "default" for system default.
          List devices with: pactl list sources short
        '';
      };

      sampleRate = lib.mkOption {
        type = lib.types.int;
        default = 16000;
        description = "Sample rate in Hz (whisper expects 16000).";
      };

      maxDurationSecs = lib.mkOption {
        type = lib.types.int;
        default = 60;
        description = "Maximum recording duration in seconds (safety limit).";
      };

      feedback = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable audio feedback sounds (beeps when recording starts/stops).";
        };

        theme = lib.mkOption {
          type = lib.types.str;
          default = "default";
          description = ''
            Sound theme: "default", "subtle", "mechanical", or path to custom theme.
          '';
        };

        volume = lib.mkOption {
          type = lib.types.float;
          default = 0.7;
          description = "Volume level (0.0 to 1.0).";
        };
      };
    };

    # Whisper configuration
    whisper = {
      language = lib.mkOption {
        type = lib.types.str;
        default = "en";
        description = ''
          Language for transcription. Use "en" for English, "auto" for auto-detection.
        '';
      };

      translate = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Translate non-English speech to English.";
      };

      threads = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Number of CPU threads for inference (null for auto-detection).";
      };

      onDemandLoading = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Load model on-demand when recording starts (true) or keep loaded (false).
          When true, model is loaded when recording starts and unloaded after.
          When false, model is kept in memory for faster response times.
        '';
      };
    };

    # Output configuration
    output = {
      mode = lib.mkOption {
        type = lib.types.enum [ "type" "clipboard" "paste" ];
        default = "type";
        description = ''
          Primary output mode:
          - type: Simulates keyboard input at cursor position
          - clipboard: Copies text to clipboard
          - paste: Copies to clipboard then pastes with Ctrl+V
        '';
      };

      fallbackToClipboard = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Fall back to clipboard if typing fails.";
      };

      typeDelayMs = lib.mkOption {
        type = lib.types.int;
        default = 0;
        description = ''
          Delay between typed characters in milliseconds.
          0 = fastest, increase if characters are dropped.
        '';
      };

      notification = {
        onRecordingStart = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Show notification when recording starts.";
        };

        onRecordingStop = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Show notification when recording stops.";
        };

        onTranscription = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Show notification with transcribed text.";
        };
      };

      postProcess = {
        command = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Pipe transcribed text through an external command for cleanup.
            The command receives text on stdin and outputs processed text on stdout.
          '';
          example = "ollama run llama3.2:1b 'Clean up this dictation...'";
        };

        timeoutMs = lib.mkOption {
          type = lib.types.int;
          default = 30000;
          description = "Timeout for post-processing command in milliseconds.";
        };
      };
    };

    # Status/tray configuration
    status = {
      iconTheme = lib.mkOption {
        type = lib.types.str;
        default = "emoji";
        description = ''
          Icon theme for status display. Options:
          - Font-based: "emoji", "nerd-font", "material", "phosphor", "codicons", "omarchy"
          - Universal: "minimal", "dots", "arrows", "text"
        '';
      };

      icons = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Per-state icon overrides.";
        example = {
          idle = "...";
          recording = "...";
          transcribing = "...";
        };
      };
    };

    # State file location
    stateFile = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      description = ''
        State file for external integrations (Waybar, polybar, etc.).
        Use "auto" for default location, a custom path, or "disabled".
      '';
    };

    # Raw settings override (escape hatch)
    settings = lib.mkOption {
      type = tomlFormat.type;
      default = { };
      description = ''
        Additional settings to merge into the config file.
        These override any settings defined by other options.
      '';
      example = lib.literalExpression ''
        {
          text = {
            spoken_punctuation = true;
            replacements = { "vox type" = "voxtype"; };
          };
        }
      '';
    };

    # Systemd service
    service = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable the systemd user service for VoxType.
          The service runs `voxtype daemon` and starts with your graphical session.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.model.name != null || cfg.model.path != null;
        message = "programs.voxtype: either model.name or model.path must be set";
      }
      {
        assertion = !(cfg.model.name != null && cfg.model.path != null);
        message = "programs.voxtype: cannot set both model.name and model.path";
      }
    ];

    home.packages = [ wrappedPackage ];

    xdg.configFile."voxtype/config.toml".source = configFile;

    systemd.user.services.voxtype = lib.mkIf cfg.service.enable {
      Unit = {
        Description = "VoxType push-to-talk voice-to-text daemon";
        Documentation = "https://voxtype.io";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" "pipewire.service" "pipewire-pulse.service" ];
      };

      Service = {
        Type = "simple";
        ExecStart = "${wrappedPackage}/bin/voxtype daemon";
        Restart = "on-failure";
        RestartSec = 5;
      };

      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
