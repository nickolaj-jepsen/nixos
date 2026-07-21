## fireproof\.agents\.skills

Agent skill directories by skill name, installed for every coding agent\.



*Type:*
attribute set of absolute path



*Default:*

```nix
{ }
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.claude-code\.work\.enable



Whether to enable claude-work wrapper sharing the personal claude-code config via ~/\.claude-work\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.desktop\.enable



Whether to enable desktop environment with niri, greetd, and all desktop features\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.desktop\.bambu-studio\.enable



Enable Bambu Studio 3D printing slicer



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.desktop\.chromium\.enable



Enable the Chromium browser



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.desktop\.google-chrome\.enable



Enable Google Chrome



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.desktop\.ivpn\.enable



Enable the IVPN client (daemon + CLI + desktop UI)



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.desktop\.jellyfin-media-player\.enable



Enable Jellyfin Media Player desktop client



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.desktop\.lan-mouse\.enable



Whether to enable Lan Mouse — LAN keyboard/mouse sharing (edge-crossing KVM)\. On niri it uses the layer-shell capture backend (no input-capture portal needed)\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.desktop\.oxcbMedia\.enable



Whether to enable 0xCB-media host daemon (bridges MPRIS + PipeWire to the 0xCB-1337 macropad over USB CDC ACM)\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.desktop\.oxcbMedia\.mprisPlayer



Pin the daemon to a specific MPRIS player\. Null lets the daemon pick automatically\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"org.mpris.MediaPlayer2.spotify"
```

*Declared by:*
 - [modules/desktop/0xcb-media\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/desktop/0xcb-media.nix)



## fireproof\.desktop\.oxcbMedia\.serialDevice



CDC ACM serial device the macropad enumerates as\.



*Type:*
string



*Default:*

```nix
"/dev/ttyACM0"
```

*Declared by:*
 - [modules/desktop/0xcb-media\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/desktop/0xcb-media.nix)



## fireproof\.desktop\.snapcast\.enable



Whether to enable Snapcast audio streaming server\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.desktop\.snapcast\.captures



Audio sources to forward into the snapcast stream\. Each entry creates
a PipeWire loopback from the named source into the snapcast sink, and
optionally a second loopback into a local monitor sink\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```

*Declared by:*
 - [modules/desktop/snapcast\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/desktop/snapcast.nix)



## fireproof\.desktop\.snapcast\.captures\.\<name>\.monitor



Optional PipeWire ` node.target ` of a sink to also play the
captured audio to (for local monitoring)\. When null, audio is
only streamed to snapcast\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [modules/desktop/snapcast\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/desktop/snapcast.nix)



## fireproof\.desktop\.snapcast\.captures\.\<name>\.source



PipeWire ` node.target ` of the source to capture from
(e\.g\. ` alsa_input.usb-Burr-Brown_from_TI_USB_Audio_CODEC-00.analog-stereo `)\.



*Type:*
string

*Declared by:*
 - [modules/desktop/snapcast\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/desktop/snapcast.nix)



## fireproof\.desktop\.snapcast\.sinkName



PipeWire ` node.name ` of the virtual sink that feeds snapserver\.
Reference this from other modules to route audio into the stream
(e\.g\. as the ` playback.props."node.target" ` of a loopback module)\.



*Type:*
string *(read only)*



*Default:*

```nix
"snapcast"
```

*Declared by:*
 - [modules/desktop/snapcast\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/desktop/snapcast.nix)



## fireproof\.dev\.enable



Whether to enable development tools and applications\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.dev\.clickhouse\.enable



Enable Clickhouse



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.dev\.intellij\.enable



Enable IntelliJ-based IDEs



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.dev\.k8s\.enable



Enable kubectl and the AO kube configs



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.dev\.mcp\.enable



Enable MCP servers (incl\. the grafana env-wrapper secret)



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.dev\.pi\.enable



Enable the pi coding agent with the lazypi extension roster



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.dev\.playwright\.enable



Enable Playwright



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.hardware\.battery



Enable battery support (UPower, battery widget, etc\.)



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.hardware\.dimmableBacklight



Enable dimmable backlight support (brightnessctl, backlight widget, etc\.)



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.hardware\.gpuPciId



PCI id of a discrete GPU to surface in DMS GPU widgets (bar gpuTemp +
system-monitor GPU temperature)\. Must match the id dgop reports
(` dgop gpu --json ` -> \.gpus\[]\.pciId), not the sysfs bus address\.
null disables the GPU widgets\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"10de:2c05"
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.hardware\.laptop



Whether to enable laptop-specific configurations and tools\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.hardware\.nvidia\.enable



Whether to enable NVIDIA GPU support (open kernel module + VA-API video offload)\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.hardware\.physical



Whether this is a physical machine (not WSL/VM)\. Enables baseline hardware hygiene: SMART monitoring, thermald, zram, btrfs scrub and journald caps\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.hardware\.wifi



Enable WiFi support (NetworkManager, wireless tools, etc\.)



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.hardware\.zram



Enable compressed RAM swap (zram) for memory-pressure headroom without writing to disk\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.homelab\.enable



Whether to enable homelab server services (arr, jellyfin, nginx, …)\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.homelab\.acmeEmail



Contact email registered with the ACME provider\.



*Type:*
string



*Default:*

```nix
"nickolaj@fireproof.website"
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.homelab\.domain



Root domain used for homelab service hostnames\.



*Type:*
string



*Default:*

```nix
"nickolaj.com"
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.hostname



The hostname of the machine



*Type:*
string

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.monitors



Per-output display configuration\.



*Type:*
list of (submodule)



*Default:*

```nix
[ ]
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.monitors\.\*\.enable



This option has no description\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.monitors\.\*\.name



This option has no description\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"DP-1"
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.monitors\.\*\.position\.x



This option has no description\.



*Type:*
signed integer



*Default:*

```nix
0
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.monitors\.\*\.position\.y



This option has no description\.



*Type:*
signed integer



*Default:*

```nix
0
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.monitors\.\*\.primary



This option has no description\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.monitors\.\*\.refreshRateNiri



This option has no description\.



*Type:*
null or floating point number



*Default:*

```nix
null
```



*Example:*

```nix
60.0
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.monitors\.\*\.resolution\.height



This option has no description\.



*Type:*
null or signed integer



*Default:*

```nix
null
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.monitors\.\*\.resolution\.width



This option has no description\.



*Type:*
null or signed integer



*Default:*

```nix
null
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.monitors\.\*\.scale



This option has no description\.



*Type:*
floating point number



*Default:*

```nix
1.0
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.monitors\.\*\.transform



This option has no description\.



*Type:*
null or signed integer



*Default:*

```nix
null
```



*Example:*

```nix
1
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.neovim\.full\.enable



Layer the heavy neovim language support (pyrefly/TS/web LSPs + their
tree-sitter grammars, nixd) on top of the always-on lean baseline\.
Defaults to dev\.enable; override off to keep the editor lean\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.networkd\.enable



Whether to enable systemd-networkd wired networking\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.theme\.colors\.accent



Primary accent color



*Type:*
string



*Default:*

```nix
"CF6A4C"
```



*Example:*

```nix
"CF6A4C"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.accentContainer



Dark container tone derived from accent



*Type:*
string



*Default:*

```nix
"6B3528"
```



*Example:*

```nix
"6B3528"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.bg



Primary background color



*Type:*
string



*Default:*

```nix
"1C1B1A"
```



*Example:*

```nix
"1C1B1A"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.bgAlt



Alternative background color



*Type:*
string



*Default:*

```nix
"282726"
```



*Example:*

```nix
"282726"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.black



Black (darkest)



*Type:*
string



*Default:*

```nix
"100F0F"
```



*Example:*

```nix
"100F0F"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.blue



Blue (info, links)



*Type:*
string



*Default:*

```nix
"4385BE"
```



*Example:*

```nix
"4385BE"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.blueAlt



Dark blue



*Type:*
string



*Default:*

```nix
"205EA6"
```



*Example:*

```nix
"205EA6"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.cyan



Cyan



*Type:*
string



*Default:*

```nix
"3AA99F"
```



*Example:*

```nix
"3AA99F"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.cyanAlt



Dark cyan



*Type:*
string



*Default:*

```nix
"24837B"
```



*Example:*

```nix
"24837B"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.fg



Primary foreground/text color



*Type:*
string



*Default:*

```nix
"DAD8CE"
```



*Example:*

```nix
"DAD8CE"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.fgAlt



Alternative foreground color



*Type:*
string



*Default:*

```nix
"B7B5AC"
```



*Example:*

```nix
"B7B5AC"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.green



Green (success)



*Type:*
string



*Default:*

```nix
"879A39"
```



*Example:*

```nix
"879A39"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.greenAlt



Dark green



*Type:*
string



*Default:*

```nix
"66800B"
```



*Example:*

```nix
"66800B"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.magenta



Magenta



*Type:*
string



*Default:*

```nix
"CE5D97"
```



*Example:*

```nix
"CE5D97"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.magentaAlt



Dark magenta



*Type:*
string



*Default:*

```nix
"A02F6F"
```



*Example:*

```nix
"A02F6F"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.muted



Muted/disabled text color



*Type:*
string



*Default:*

```nix
"878580"
```



*Example:*

```nix
"878580"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.orange



Orange (warnings)



*Type:*
string



*Default:*

```nix
"DA702C"
```



*Example:*

```nix
"DA702C"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.orangeAlt



Dark orange



*Type:*
string



*Default:*

```nix
"BC5215"
```



*Example:*

```nix
"BC5215"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.purple



Purple



*Type:*
string



*Default:*

```nix
"8B7EC8"
```



*Example:*

```nix
"8B7EC8"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.purpleAlt



Dark purple



*Type:*
string



*Default:*

```nix
"5E409D"
```



*Example:*

```nix
"5E409D"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.red



Red (errors, destructive)



*Type:*
string



*Default:*

```nix
"D14D41"
```



*Example:*

```nix
"D14D41"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.redAlt



Dark red



*Type:*
string



*Default:*

```nix
"AF3029"
```



*Example:*

```nix
"AF3029"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.ui



UI element background



*Type:*
string



*Default:*

```nix
"343331"
```



*Example:*

```nix
"343331"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.uiAlt



Alternative UI element background



*Type:*
string



*Default:*

```nix
"403E3C"
```



*Example:*

```nix
"403E3C"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.white



White (same as fg)



*Type:*
string



*Default:*

```nix
"DAD8CE"
```



*Example:*

```nix
"DAD8CE"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.whiteAlt



Bright white



*Type:*
string



*Default:*

```nix
"F2F0E5"
```



*Example:*

```nix
"F2F0E5"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.yellow



Yellow (caution)



*Type:*
string



*Default:*

```nix
"D0A215"
```



*Example:*

```nix
"D0A215"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.theme\.colors\.yellowAlt



Dark yellow



*Type:*
string



*Default:*

```nix
"AD8301"
```



*Example:*

```nix
"AD8301"
```

*Declared by:*
 - [modules/base/theme\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix)



## fireproof\.username



The primary username for the machine



*Type:*
string



*Default:*

```nix
"nickolaj"
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.work\.enable



Whether to enable work-related applications and tools\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)



## fireproof\.wsl\.enable



Whether to enable WSL configuration\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix)


