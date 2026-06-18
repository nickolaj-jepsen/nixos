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
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.desktop\.enable



Whether to enable Enable desktop environment with niri, greetd, and all desktop features\.



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
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.desktop\.bambu-studio\.enable



Enable Bambu Studio 3D printing slicer



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.desktop\.chromium\.enable



Enable the Chromium browser



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.desktop\.google-chrome\.enable



Enable Google Chrome



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.desktop\.greeter\.enable



Enable the greetd display manager



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



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
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



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
 - [modules/desktop/0xcb-media\.nix, via option flake\.modules\.nixos\.oxcb-media](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/desktop/0xcb-media.nix, via option flake.modules.nixos.oxcb-media)



## fireproof\.desktop\.oxcbMedia\.serialDevice



CDC ACM serial device the macropad enumerates as\.



*Type:*
string



*Default:*

```nix
"/dev/ttyACM0"
```

*Declared by:*
 - [modules/desktop/0xcb-media\.nix, via option flake\.modules\.nixos\.oxcb-media](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/desktop/0xcb-media.nix, via option flake.modules.nixos.oxcb-media)



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
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



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
 - [modules/desktop/snapcast\.nix, via option flake\.modules\.nixos\.snapcast](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/desktop/snapcast.nix, via option flake.modules.nixos.snapcast)



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
 - [modules/desktop/snapcast\.nix, via option flake\.modules\.nixos\.snapcast](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/desktop/snapcast.nix, via option flake.modules.nixos.snapcast)



## fireproof\.desktop\.snapcast\.captures\.\<name>\.source



PipeWire ` node.target ` of the source to capture from
(e\.g\. ` alsa_input.usb-Burr-Brown_from_TI_USB_Audio_CODEC-00.analog-stereo `)\.



*Type:*
string

*Declared by:*
 - [modules/desktop/snapcast\.nix, via option flake\.modules\.nixos\.snapcast](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/desktop/snapcast.nix, via option flake.modules.nixos.snapcast)



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
 - [modules/desktop/snapcast\.nix, via option flake\.modules\.nixos\.snapcast](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/desktop/snapcast.nix, via option flake.modules.nixos.snapcast)



## fireproof\.desktop\.windowManager\.enable



Enable window manager (niri) and dank material shell (dms)



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.dev\.enable



Whether to enable Enable development tools and applications\.



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
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.dev\.clickhouse\.enable



Enable Clickhouse



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.dev\.intellij\.enable



Enable IntelliJ-based IDEs



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.dev\.playwright\.enable



Enable Playwright



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.hardware\.battery



Enable battery support (UPower, battery widget, etc\.)



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.hardware\.dimmableBacklight



Enable dimmable backlight support (brightnessctl, backlight widget, etc\.)



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



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
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.hardware\.laptop



Whether to enable Enable laptop-specific configurations and tools\.



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
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



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
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.hardware\.physical



Whether this is a physical machine (not WSL/VM)\. Enables baseline hardware hygiene: SMART monitoring, thermald, zram, btrfs scrub and journald caps\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.hardware\.wifi



Enable WiFi support (NetworkManager, wireless tools, etc\.)



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.hardware\.zram



Enable compressed RAM swap (zram) for memory-pressure headroom without writing to disk\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



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
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.homelab\.acmeEmail



Contact email registered with the ACME provider\.



*Type:*
string



*Default:*

```nix
"nickolaj@fireproof.website"
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.homelab\.domain



Root domain used for homelab service hostnames\.



*Type:*
string



*Default:*

```nix
"nickolaj.com"
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.hostname



The hostname of the machine



*Type:*
string

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.monitors



Per-output display configuration\.



*Type:*
list of (submodule)



*Default:*

```nix
[ ]
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.monitors\.\*\.enable



This option has no description\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



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
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.monitors\.\*\.position\.x



This option has no description\.



*Type:*
signed integer



*Default:*

```nix
0
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.monitors\.\*\.position\.y



This option has no description\.



*Type:*
signed integer



*Default:*

```nix
0
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.monitors\.\*\.primary



This option has no description\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



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
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.monitors\.\*\.resolution\.height



This option has no description\.



*Type:*
null or signed integer



*Default:*

```nix
null
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.monitors\.\*\.resolution\.width



This option has no description\.



*Type:*
null or signed integer



*Default:*

```nix
null
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.monitors\.\*\.scale



This option has no description\.



*Type:*
floating point number



*Default:*

```nix
1.0
```

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



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
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



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
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



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
 - [modules/base/theme\.nix, via option flake\.modules\.nixos\.theme](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/theme.nix, via option flake.modules.nixos.theme)



## fireproof\.username



The primary username for the machine



*Type:*
string

*Declared by:*
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.work\.enable



Whether to enable Enable work-related applications and tools\.



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
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)



## fireproof\.wsl\.enable



Whether to enable Enable WSL configuration\.



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
 - [modules/base/fireproof\.nix, via option flake\.modules\.nixos\.fireproof-options](https://github.com/nickolaj-jepsen/nixos/blob/main/modules/base/fireproof.nix, via option flake.modules.nixos.fireproof-options)


