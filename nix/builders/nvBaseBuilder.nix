patcher:
{
  # We require nixpkgs because the wrapper parses it later
  nixpkgs
  , system
  , dependencyOverlays
}:
# TODO: Get specialArgs to work
{ configuration, specialArgs ? null, extra_pkg_config ? {} }:
let
  utils = import ../utils;

  name = "nv";

  pkgs = import nixpkgs ({
    inherit system;
    overlays = if builtins.isList dependencyOverlays
        then dependencyOverlays
        else if builtins.isAttrs dependencyOverlays && builtins.hasAttr system dependencyOverlays
        then dependencyOverlays.${system}
        else [];
  } // { config = extra_pkg_config; });
  lib = pkgs.lib;

  rawconfiguration = configuration { inherit pkgs; };

  finalConfiguration = {
    # luaPath cannot be merged
    plugins = [ ];
    aliases = [ ];
    runtimeDeps = [ ];
    environmentVariables = { };
    extraWrapperArgs = [ ];

    python3Packages = [ ];
    extraPython3WrapperArgs = [ ];

    luaPackages = [ ];

    propagatedBuildInputs = [ ];
    sharedLibraries = [ ];

    extraConfig = [ ];
    customSubs = [ ];
  } 
  // rawconfiguration;

  finalSettings = {
    withNodeJs = false;
    withRuby = false;
    withPerl = false;
    withPython3 = false;
    extraName = "";
    configDirName = "nvim";
    aliases = null;
    neovim-unwrapped = null;

    suffix-path = false;
    suffix-LD = false;
    disablePythonSafePath = false;
  }
  // rawconfiguration.settings
  # TODO: Make wrapRc optional by adding an option to put
  # config in xdg.config
  // { wrapRc = true; };

  inherit (finalConfiguration) 
    luaPath plugins runtimeDeps extraConfig
    environmentVariables python3Packages 
    extraPython3WrapperArgs customSubs
    extraWrapperArgs sharedLibraries luaPackages;

  inherit (finalSettings)
    withNodeJs withRuby withPerl withPython3
    extraName configDirName aliases 
    neovim-unwrapped suffix-path
    suffix-LD disablePythonSafePath wrapRc;

  neovim = if neovim-unwrapped == null then pkgs.neovim-unwrapped else neovim-unwrapped;

  # Setup environments
  appendPathPos = if suffix-path then "suffix" else "prefix";
  appendLinkPos = if suffix-LD then "suffix" else "prefix";

  getEnv = env:  lib.flatten 
    (lib.mapAttrsToList (n: v: [ "--set" "${n}" "${v}" ]) env);
 
  wrapperArgs = 
    let
      binPath = lib.makeBinPath (runtimeDeps
        ++ lib.optionals withNodeJs 
        [ pkgs.nodejs ]
        ++ lib.optionals withRuby
        [ pkgs.ruby ]);
        
    in 
    getEnv environmentVariables
    ++
    lib.optionals (configDirName != null && configDirName != "nvim")
    [ "--set" "NVIM_APPNAME" "${configDirName}" ]
    ++ lib.optionals (runtimeDeps != [])
    [ "--${appendPathPos}" "PATH" ":" "${binPath}" ]
    ++ lib.optionals (sharedLibraries != [])
    [ "--${appendLinkPos}" "PATH" ":" "${lib.makeBinPath sharedLibraries}" ]
    ++
    (
     if builtins.isList extraWrapperArgs then extraWrapperArgs 
     else if builtins.isString then [extraWrapperArgs]
     else throw "extraWrapperArgs should be a string or list of strings"
    );

  extraPython3Packages = utils.combineFns python3Packages;
  extraLuaPackages = utils.combineFns luaPackages;

  mappedPlugins = map (p: { plugin = p; optional = true; }) plugins;

  cfg = pkgs.neovimUtils.makeNeovimConfig {
    inherit withPython3 extraPython3Packages;
    inherit withNodeJs;
    inherit withRuby;
    inherit extraLuaPackages;

    plugins = mappedPlugins;
  };

  perlEnv = pkgs.perl.withPackages (p: [ p.NeovimExt p.Appcpanminus ]);

  luaConfig = patcher {
    inherit luaPath plugins name;
    inherit extraConfig customSubs;

    inherit withNodeJs;
    inherit withRuby ;
    inherit withPerl perlEnv;
    inherit withPython3 extraPython3WrapperArgs ;

    inherit (cfg) rubyEnv python3Env;
  };

in
(pkgs.callPackage ./neovimWrapper.nix {}) neovim {
    inherit luaConfig;
    inherit wrapRc wrapperArgs;
    inherit aliases;
    inherit name extraName;
    inherit (cfg) packpathDirs manifestRc;
}
