# Multi-bulb targets are always Zigbee group entities: one multicast, no per-bulb timeout.
{
  lib,
  dev,
}: let
  inherit (dev) light switch group slug actionTopic;
  inherit (dev) person spotify alSwitch alSleep alRooms;
  inherit (dev.helpers) sleepMode guestMode zwiftRide watchingManual mqttTriggersArmed awaySimulation;
  manual = room: dev.helpers."${room}Manual";
  shield = dev.jellyfinShield;
  bedroomCeiling = light "Bedroom - Ceiling light";
  deskLamp = light "Bedroom - Desk lamp";
  bedroomFan = switch dev.outlets.bedroomFan;
  kitchenFan = switch dev.outlets.kitchenFan;
  officeAudio = switch dev.outlets.officeAudio;
  doorContact = dev.sensors."Entrance - Door".contact;
  hallwaySensors = {
    stairs = dev.sensors."Stairs - Movement sensor";
    entrance = dev.sensors."Entrance - Movement sensor";
  };

  # Turn-on level: what Adaptive Lighting is about to set, read off its switch. A bulb
  # turned on without a level comes up at its last one (100 % from the afternoon) and
  # is dimmed a second later. With the switch off or unavailable the attribute is None:
  # a fixed night level then (sleep mode, or late hours when goodnight was never pressed).
  isNight = "is_state('${sleepMode}','on') or now().hour >= 23 or now().hour < 6";
  alLevel = room: "{{ state_attr('${alSwitch room}','brightness_pct') | int(15 if (${isNight}) else 100) }}";

  # ---- conditions ------------------------------------------------------------
  template = t: {
    condition = "template";
    value_template = t;
  };
  # Group entities read `unknown` until a member reports; a state condition then matches neither on nor off.
  groupOn = e: template "{{ is_state('${e}','on') }}";
  groupOff = e: template "{{ not is_state('${e}','on') }}";
  # Not sun.is_night: at 56° N the sun never reaches -18° from mid-May to late July.
  sunBelow = deg: {
    condition = "sun.elevation";
    options.threshold = {
      type = "below";
      value.number = deg;
    };
  };
  isOff = e: {
    condition = "state";
    entity_id = e;
    state = "off";
  };
  isOn = e: {
    condition = "state";
    entity_id = e;
    state = "on";
  };
  personIs = state: {
    condition = "state";
    entity_id = person;
    inherit state;
  };
  # Timestamp checks instead of `for:` timers survive the automation.reload the MQTT recovery
  # runs at every start; last_updated also moves on brightness changes (activity outside AL).
  staleBy = attr: minutes: e: "(states['${e}'] is not none and (now() - states['${e}'].${attr}).total_seconds() > ${toString (minutes * 60)})";
  stale = staleBy "last_changed";
  idle = staleBy "last_updated";
  everyFiveMinutes = {
    trigger = "time_pattern";
    minutes = "/5";
  };
  onTrigger = id: sequence: {
    conditions = [
      {
        condition = "trigger";
        inherit id;
      }
    ];
    inherit sequence;
  };

  # ---- actions ---------------------------------------------------------------
  turnOn = target: data: {
    action = "light.turn_on";
    target.entity_id = target;
    inherit data;
  };
  turnOff = target: {
    action = "light.turn_off";
    target.entity_id = target;
  };
  step = target: pct: turnOn target {brightness_step_pct = pct;};
  plugOn = e: {
    action = "switch.turn_on";
    target.entity_id = e;
  };
  plugOff = e: {
    action = "switch.turn_off";
    target.entity_id = e;
  };
  setBool = e: on: {
    action = "input_boolean.turn_${
      if on
      then "on"
      else "off"
    }";
    target.entity_id = e;
  };
  setNumber = e: value: {
    action = "number.set_value";
    target.entity_id = e;
    data.value = value;
  };
  discord = message: {
    action = "rest_command.discord";
    data.message = message;
  };
  # The inner `data` is the companion-app payload; only the legacy per-device action accepts it.
  phone = {
    message,
    title ? null,
    channel,
    tag ? null,
    actions ? [],
  }: {
    action = dev.phoneNotifyAction;
    data =
      {
        inherit message;
        data =
          {inherit channel;}
          // lib.optionalAttrs (tag != null) {inherit tag;}
          // lib.optionalAttrs (actions != []) {inherit actions;};
      }
      // lib.optionalAttrs (title != null) {inherit title;};
  };
  pausePlayers = {
    action = "media_player.media_pause";
    target.entity_id = [shield spotify];
    continue_on_error = true;
  };

  roomLights = room: map light dev.rooms.${room}.lights;
  # Adaptive Lighting tracks the individual bulbs, never the group entity.
  alManualFor = room: lights: on: {
    action = "adaptive_lighting.set_manual_control";
    data = {
      entity_id = alSwitch room;
      inherit lights;
      manual_control = on;
    };
  };
  alManual = room: alManualFor room (roomLights room);
  alApply = room: {
    action = "adaptive_lighting.apply";
    data = {
      entity_id = alSwitch room;
      lights = roomLights room;
      turn_on_lights = false;
    };
  };

  holdUp = room: [
    {
      "if" = [(groupOn (group room))];
      "then" = [(step (group room) 20)];
      "else" = [(turnOn (group room) {})];
    }
  ];
  holdDown = room: [
    {
      "if" = [(groupOn (group room))];
      "then" = [(step (group room) (-20))];
    }
  ];
  # 2200-4000 K is the bulbs' range.
  ctWarmer = room:
    turnOn (group room) {
      color_temp_kelvin = "{{ [ (state_attr('${group room}','color_temp_kelvin') | int(3000)) - 300, 2200 ] | max }}";
    };
  ctCooler = room:
    turnOn (group room) {
      color_temp_kelvin = "{{ [ (state_attr('${group room}','color_temp_kelvin') | int(3000)) + 300, 4000 ] | min }}";
    };

  # Queued so a double press is never dropped.
  remote = name: actions: {
    id = "remote_${slug name}";
    alias = "Remote: ${name}";
    mode = "queued";
    max = 10;
    triggers =
      lib.mapAttrsToList (action: _: {
        trigger = "mqtt";
        topic = actionTopic name;
        payload = action;
        id = action;
      })
      actions;
    actions = [
      {
        choose = lib.mapAttrsToList onTrigger actions;
      }
    ];
  };

  # A Kitchen press during playback owns the living room until playback stops.
  watchingLatch = {
    "if" = [(template "{{ states('${shield}') in ['playing','paused'] }}")];
    "then" = [(setBool watchingManual true)];
  };

  motion = {
    room,
    sensor,
    onActions,
    offTarget,
    whenDark,
  }: [
    {
      # Gated on the room being off: a re-trigger would overwrite a manual level.
      id = "motion_${room}_on";
      alias = "Motion: ${room} on";
      mode = "single";
      triggers = [
        {
          trigger = "state";
          entity_id = sensor.occupancy;
          to = "on";
        }
      ];
      # The sensor already drops bright-light reports; only the sun gate is worth adding.
      conditions = lib.optional whenDark (sunBelow 3) ++ [(groupOff offTarget)];
      actions = onActions;
    }
    {
      id = "motion_${room}_off";
      alias = "Motion: ${room} off";
      mode = "restart";
      triggers = [
        {
          trigger = "state";
          entity_id = sensor.occupancy;
          to = "off";
          for = "{{ '00:15:00' if is_state('${guestMode}','on') else '00:02:00' }}";
        }
      ];
      conditions = [(isOff (manual room))];
      actions = [(turnOff offTarget)];
    }
    {
      # A switch press owns the room until its light goes off again.
      id = "motion_${room}_manual_reset";
      alias = "Motion: ${room} manual reset";
      triggers = [
        {
          trigger = "state";
          entity_id = offTarget;
          to = "off";
          for = "00:00:10";
        }
      ];
      actions = [(setBool (manual room) false)];
    }
  ];

  doorOpenNotice = phone {
    title = "Door";
    channel = "Door";
    tag = "door-open";
    message = "The entrance door has been open for {{ ((now() - states['${doorContact}'].last_changed).total_seconds() / 60) | round | int }} minutes.";
    actions = [
      {
        action = "DOOR_REMIND";
        title = "Remind me in 30 min";
      }
    ];
  };

  zigbeeWatch = dev.routerEntities ++ dev.batteryEntities;
in {
  automation =
    [
      # ---- remotes -------------------------------------------------------------
      (remote "Office - Switch" {
        "on" = [
          {
            "if" = [(groupOn (group "office"))];
            "then" = [(step (group "office") 20)];
            "else" = [(turnOn (group "office") {})];
          }
        ];
        "off" = [(step (group "office") (-20))];
        brightness_move_up = [(turnOn (group "office") {brightness_pct = 100;})];
        brightness_move_down = [(turnOff (group "office"))];
        arrow_left_click = [(ctWarmer "office")];
        arrow_right_click = [(ctCooler "office")];
      })
      (remote "Bedroom - Switch" {
        "on" = [(turnOn (group "bedroom") {brightness_pct = alLevel "bedroom";})];
        "off" = [(turnOff (group "bedroom"))];
        brightness_move_up = holdUp "bedroom";
        brightness_move_down = holdDown "bedroom";
      })
      (remote "Kitchen - Switch" {
        "on" = [watchingLatch (turnOn (group "living_room") {brightness_pct = alLevel "living_room";})];
        "off" = [watchingLatch (turnOff (group "living_room"))];
        brightness_move_up = [watchingLatch] ++ holdUp "living_room";
        brightness_move_down = [watchingLatch] ++ holdDown "living_room";
      })
      (remote "Stairs - Switch top" {
        "on" = [(setBool (manual "stairs") true) (turnOn (group "stairs") {brightness_pct = alLevel "stairs";})];
        "off" = [(turnOff (group "stairs")) (turnOff (group "entrance")) (turnOff (group "living_room"))];
        brightness_move_up = holdUp "stairs";
        brightness_move_down = holdDown "stairs";
      })
      (remote "Stairs - Switch bottom" {
        "on" = [
          (setBool (manual "stairs") true)
          (setBool (manual "entrance") true)
          (turnOn (group "stairs") {brightness_pct = alLevel "stairs";})
          (turnOn (group "entrance") {brightness_pct = alLevel "entrance";})
        ];
        "off" = [(turnOff (group "stairs")) (turnOff (group "entrance"))];
        brightness_move_up = holdUp "stairs";
        brightness_move_down = holdDown "stairs";
      })
      (remote "Bedroom - Bed switch" {
        "on" = [
          (turnOn deskLamp {
            brightness_pct = 10;
            color_temp_kelvin = 2200;
          })
          (plugOn bedroomFan)
        ];
        brightness_move_up = [
          (turnOn (group "bedroom") {})
          {
            # The same hold lights the room for a night trip or an evening read; only a morning one ends sleep mode.
            "if" = [(template "{{ 5 <= now().hour < 12 }}")];
            "then" = [(setBool sleepMode false)];
          }
        ];
        "off" = [
          (turnOff (group "all"))
          (plugOff [bedroomFan kitchenFan])
        ];
        brightness_move_down = [{action = "script.goodnight";}];
      })
      (remote "Bathroom - Switch" {
        # Re-sent after 2 s so a bulb that missed the multicast catches up; the group state cannot tell.
        "on" = [
          (turnOn (group "bathroom") {brightness_pct = alLevel "bathroom";})
          {delay.seconds = 2;}
          (turnOn (group "bathroom") {brightness_pct = alLevel "bathroom";})
        ];
        "off" = [(turnOff (group "bathroom"))];
        brightness_move_up = [(step (group "bathroom") 20)];
        brightness_move_down = [(step (group "bathroom") (-20))];
      })
    ]
    # ---- motion ----------------------------------------------------------------
    ++ (motion {
      room = "stairs";
      sensor = hallwaySensors.stairs;
      # Dark at noon; the sensor's own light check is off via the Z2M device option illuminance_below_threshold_check.
      whenDark = false;
      onActions = [(turnOn (group "stairs") {brightness_pct = alLevel "stairs";})];
      offTarget = group "stairs";
    })
    ++ (motion {
      room = "entrance";
      sensor = hallwaySensors.entrance;
      whenDark = true;
      onActions = [
        {
          action = "script.entrance_animation";
          data.brightness_pct = alLevel "entrance";
        }
      ];
      offTarget = group "entrance";
    })
    ++ [
      {
        # The sensors never send "cleared": Zigbee2MQTT fakes it with an in-process timer,
        # so a bridge restart mid-motion strands the hallway on.
        id = "motion_watchdog";
        alias = "Motion: hallway watchdog";
        mode = "single";
        triggers = [everyFiveMinutes];
        actions =
          lib.mapAttrsToList (room: sensor: {
            "if" = [
              (groupOn (group room))
              (isOff (manual room))
              (template "{{ ${stale 60 (group room)} and ${stale 60 sensor.occupancy} }}")
            ];
            "then" = [(turnOff (group room))];
          })
          hallwaySensors;
      }
      {
        # Only the RODRET ever turns the bathroom off, and it has no motion sensor.
        id = "bathroom_auto_off";
        alias = "Bathroom: auto off after 45 minutes";
        mode = "single";
        triggers = [everyFiveMinutes];
        conditions = [
          (groupOn (group "bathroom"))
          (template "{{ ${idle 45 (group "bathroom")} }}")
        ];
        actions = [(turnOff (group "bathroom"))];
      }
      # ---- presence --------------------------------------------------------------
      {
        id = "presence_leave";
        alias = "Presence: leaving turns everything off";
        triggers = [
          {
            trigger = "state";
            entity_id = person;
            from = "home";
            to = "not_home";
            # The one automation that switches everything off; a GPS wobble must not.
            for = "00:02:00";
          }
        ];
        conditions = [(isOff guestMode)];
        actions = [
          (turnOff (group "all"))
          (plugOff [bedroomFan kitchenFan])
          pausePlayers
        ];
      }
      {
        id = "presence_arrive";
        alias = "Presence: arriving after dark lights the way";
        triggers = [
          {
            trigger = "state";
            entity_id = person;
            from = "not_home";
            to = "home";
          }
          {
            # The door opens before GPS notices; counts only while away or just arrived.
            trigger = "state";
            entity_id = doorContact;
            to = "on";
          }
        ];
        conditions = [
          (sunBelow 3)
          (groupOff (group "entrance"))
          (isOff sleepMode)
          (template "{{ is_state('${person}', 'not_home') or (now() - states['${person}'].last_changed).total_seconds() < 600 }}")
        ];
        actions = [
          (turnOn (group "entrance") {brightness_pct = alLevel "entrance";})
          (turnOn (group "stairs") {brightness_pct = alLevel "stairs";})
        ];
      }
      # ---- door ------------------------------------------------------------------
      {
        id = "door_left_open";
        alias = "Door: left open";
        triggers = [
          {
            trigger = "state";
            entity_id = doorContact;
            to = "on";
            for = "00:10:00";
          }
        ];
        actions = [doorOpenNotice];
      }
      {
        id = "door_remind";
        alias = "Door: remind me in 30 minutes";
        mode = "single";
        triggers = [
          {
            trigger = "event";
            event_type = "mobile_app_notification_action";
            event_data.action = "DOOR_REMIND";
          }
        ];
        actions = [
          {delay.minutes = 30;}
          (isOn doorContact)
          doorOpenNotice
        ];
      }
      {
        id = "door_opened_while_away";
        alias = "Door: opened while away";
        triggers = [
          {
            trigger = "state";
            entity_id = doorContact;
            to = "on";
          }
        ];
        conditions = [(personIs "not_home")];
        actions = [
          (phone {
            title = "Door";
            channel = "Door";
            tag = "door-away";
            message = "The entrance door opened at {{ now().strftime('%H:%M') }} while nobody is home.";
          })
        ];
      }
      # ---- sleep mode ------------------------------------------------------------
      {
        id = "sleep_mode_sync";
        alias = "Sleep mode: sync Adaptive Lighting";
        triggers = [
          {
            trigger = "state";
            entity_id = sleepMode;
            # The service name is templated from the state, so anything but on/off
            # (unavailable on reload, or a removal with no to_state) must not trigger.
            to = ["on" "off"];
          }
        ];
        # One call per room: a sleep switch whose registry id differs from alSleep
        # (a freshly added room) must not stop the others from syncing.
        actions =
          map (r: {
            action = "switch.turn_{{ trigger.to_state.state }}";
            target.entity_id = alSleep r;
            continue_on_error = true;
          })
          alRooms;
      }
      {
        id = "sleep_mode_safety";
        alias = "Sleep mode: off by mid-morning";
        triggers = [
          {
            trigger = "time";
            at = "10:00:00";
          }
        ];
        actions = [
          (setBool sleepMode false)
          (setBool (manual "stairs") false)
          (setBool (manual "entrance") false)
          (alManualFor "bedroom" [bedroomCeiling] false)
        ];
      }
      # ---- alarm (Sleep as Android, core webhook integration) --------------------
      {
        id = "alarm_start";
        alias = "Alarm: alert starts";
        mode = "single";
        triggers = [
          {
            trigger = "event.received";
            target.entity_id = dev.saa.alarmEvent;
            options.event_type = ["alert_start"];
          }
        ];
        actions = [
          (setBool sleepMode false)
          (alManualFor "bedroom" [bedroomCeiling] false)
          (turnOn bedroomCeiling {})
          (turnOn (group "stairs") {})
        ];
      }
      {
        id = "alarm_dismiss";
        alias = "Alarm: alert dismissed";
        mode = "single";
        triggers = [
          {
            trigger = "event.received";
            target.entity_id = dev.saa.alarmEvent;
            options.event_type = ["alert_dismiss"];
          }
        ];
        actions = [(setBool sleepMode false)];
      }
      {
        # The two alarm sources can differ by minutes for one alarm; a run within 15 min of the last is a repeat.
        id = "alarm_ramp";
        alias = "Alarm: bedroom ramps up before the alarm";
        mode = "single";
        triggers = [
          {
            trigger = "time";
            at = {
              entity_id = dev.saa.nextAlarm;
              offset = "-00:10:00";
            };
          }
          {
            trigger = "time";
            at = {
              entity_id = dev.phoneNextAlarm;
              offset = "-00:10:00";
            };
          }
        ];
        conditions = [
          (personIs "home")
          (template "{{ this.attributes.last_triggered is none or (now() - this.attributes.last_triggered).total_seconds() > 900 }}")
        ];
        actions = [
          (alManualFor "bedroom" [bedroomCeiling] true)
          (turnOn bedroomCeiling {brightness_pct = 1;})
          (turnOn bedroomCeiling {
            brightness_pct = 60;
            transition = 600;
          })
        ];
      }
      # ---- ride mode (Zwift) -----------------------------------------------------
      {
        id = "zwift_ride_on";
        alias = "Zwift: ride mode on";
        mode = "single";
        triggers = [
          {
            trigger = "state";
            entity_id = dev.zwift.online;
            to = "True";
          }
        ];
        conditions = [(personIs "home")];
        actions = [
          (setBool zwiftRide true)
          (plugOn kitchenFan)
          (setNumber dev.zwift.updateInterval 15)
          (alManual "living_room" true)
          (turnOn (group "living_room") {
            brightness_pct = 100;
            color_temp_kelvin = 3500;
          })
        ];
      }
      {
        # No `from:` and a start trigger: after a restart the sensor goes unknown -> False, which an
        # exact transition never catches. The latch keeps a hand-switched fan untouched.
        id = "zwift_ride_off";
        alias = "Zwift: ride mode off";
        mode = "single";
        triggers = [
          {
            trigger = "state";
            entity_id = dev.zwift.online;
            to = "False";
            for = "00:10:00";
          }
          {
            trigger = "homeassistant";
            event = "start";
          }
        ];
        conditions = [
          (isOn zwiftRide)
          (template "{{ not is_state('${dev.zwift.online}','True') }}")
        ];
        actions = [
          (plugOff kitchenFan)
          {
            # A film still running keeps the room at the watching level; watching_stop hands it back later.
            "if" = [(template "{{ states('${shield}') not in ['playing','paused'] }}")];
            "then" = [(alManual "living_room" false) (alApply "living_room")];
            "else" = [
              (turnOn (group "living_room") {
                brightness_pct = 20;
                color_temp_kelvin = 2200;
                transition = 2;
              })
            ];
          }
          (setNumber dev.zwift.updateInterval 120)
          (setBool zwiftRide false)
        ];
      }
      {
        id = "zwift_zone_tint";
        alias = "Zwift: colour temperature follows the power zone";
        mode = "single";
        triggers = [
          {
            trigger = "state";
            entity_id = dev.zwift.powerZone;
          }
        ];
        conditions = [(isOn zwiftRide)];
        actions = [
          (turnOn (group "living_room") {
            brightness_pct = 100;
            color_temp_kelvin = "{{ 3000 if (states('${dev.zwift.powerZone}') | int(3)) <= 2 else (3500 if (states('${dev.zwift.powerZone}') | int(3)) == 3 else 4000) }}";
          })
        ];
      }
      {
        id = "zwift_polling_idle";
        alias = "Zwift: slow polling while idle";
        mode = "single";
        triggers = [
          {
            trigger = "homeassistant";
            event = "start";
          }
        ];
        conditions = [(template "{{ not is_state('${dev.zwift.online}','True') }}")];
        actions = [(setNumber dev.zwift.updateInterval 120)];
      }
      # ---- watching mode (Jellyfin on the Shield) --------------------------------
      {
        id = "watching_play";
        alias = "Watching: dim on play";
        mode = "single";
        triggers = [
          {
            trigger = "state";
            entity_id = shield;
            to = "playing";
          }
        ];
        conditions = [(sunBelow 3) (isOff sleepMode) (isOff watchingManual) (isOff zwiftRide)];
        actions = [
          (alManual "living_room" true)
          (turnOn (group "living_room") {
            brightness_pct = 20;
            color_temp_kelvin = 2200;
            transition = 2;
          })
        ];
      }
      {
        id = "watching_pause";
        alias = "Watching: half brightness on pause";
        mode = "single";
        triggers = [
          {
            trigger = "state";
            entity_id = shield;
            from = "playing";
            to = "paused";
          }
        ];
        conditions = [(isOff watchingManual) (sunBelow 3) (isOff zwiftRide)];
        actions = [
          (turnOn (group "living_room") {
            brightness_pct = 50;
            transition = 2;
          })
        ];
      }
      {
        id = "watching_stop";
        alias = "Watching: Adaptive Lighting takes the room back";
        mode = "single";
        triggers = [
          {
            trigger = "state";
            entity_id = shield;
            to = ["idle" "off" "unavailable" "unknown"];
            for = "00:02:00";
          }
        ];
        actions = [
          (setBool watchingManual false)
          {
            # Ride mode owns the room until the ride ends.
            "if" = [(isOff zwiftRide)];
            "then" = [(alManual "living_room" false) (alApply "living_room")];
          }
        ];
      }
      # ---- office ----------------------------------------------------------------
      {
        # A NIC kept alive for wake-on-LAN can hold the tracker home.
        id = "office_audio_follows_pc";
        alias = "Office: speakers follow the PC";
        mode = "queued";
        triggers = [
          {
            trigger = "state";
            entity_id = dev.pcTracker;
            to = "home";
            id = "pc_on";
          }
          {
            trigger = "state";
            entity_id = dev.pcTracker;
            to = "not_home";
            for = "00:10:00";
            id = "pc_off";
          }
        ];
        actions = [
          {
            choose = [
              (onTrigger "pc_on" [(plugOn officeAudio)])
              (onTrigger "pc_off" [(plugOff officeAudio)])
            ];
          }
        ];
      }
      # ---- away simulation -------------------------------------------------------
      {
        id = "away_simulation_flag";
        alias = "Away: simulation flag";
        mode = "queued";
        triggers = [
          {
            trigger = "state";
            entity_id = person;
            to = "not_home";
            for.hours = 24;
            id = "away";
          }
          {
            trigger = "state";
            entity_id = person;
            to = "home";
            id = "back";
          }
        ];
        actions = [
          {
            choose = [
              (onTrigger "away" [(setBool awaySimulation true)])
              (onTrigger "back" [(setBool awaySimulation false)])
            ];
          }
        ];
      }
      {
        # The mid-sequence conditions are the cancel: arriving clears the flag and the run stops there.
        id = "away_simulation_evening";
        alias = "Away: evening pattern";
        mode = "restart";
        triggers = [
          {
            trigger = "sun";
            event = "sunset";
          }
        ];
        conditions = [(isOn awaySimulation) (isOff guestMode)];
        actions = [
          (turnOn (group "living_room") {})
          {delay.minutes = "{{ range(0, 45) | random }}";}
          (isOn awaySimulation)
          # June sunsets pass 22:00; the office must not come on after the 22:30 lights-out.
          (template "{{ now().hour < 22 }}")
          (turnOn (group "office") {})
          {delay.minutes = 90;}
          (isOn awaySimulation)
          (turnOff (group "office"))
        ];
      }
      {
        id = "away_simulation_night";
        alias = "Away: lights out for the night";
        mode = "restart";
        triggers = [
          {
            trigger = "time";
            at = "22:30:00";
          }
        ];
        conditions = [(isOn awaySimulation) (isOff guestMode)];
        actions = [
          {delay.minutes = "{{ range(0, 60) | random }}";}
          (isOn awaySimulation)
          (turnOff (group "all"))
        ];
      }
      # ---- weather ---------------------------------------------------------------
      {
        id = "weather_warning";
        alias = "Weather: DMI warning";
        triggers = [
          {
            trigger = "state";
            entity_id = dev.meteoalarm;
            to = "on";
          }
        ];
        actions = [
          (discord "⚠️ DMI warning: {{ state_attr('${dev.meteoalarm}','headline') }} ({{ state_attr('${dev.meteoalarm}','severity') }}) — {{ state_attr('${dev.meteoalarm}','description') | default('', true) | truncate(300) }}")
        ];
      }
      # ---- printer (Bambu Lab; ids are provisional, see _devices.nix) -------------
      {
        id = "printer_finished";
        alias = "Printer: print finished";
        triggers = [
          {
            trigger = "state";
            entity_id = dev.printer.status;
            to = "finish";
          }
        ];
        actions = [
          (phone {
            title = "Printer";
            channel = "Printer";
            tag = "printer";
            message = "Print finished: {{ states('${dev.printer.taskName}') }}";
          })
        ];
      }
      {
        id = "printer_failed";
        alias = "Printer: print failed";
        triggers = [
          {
            trigger = "state";
            entity_id = dev.printer.status;
            to = "failed";
          }
        ];
        actions = [
          (phone {
            title = "Printer";
            channel = "Printer";
            tag = "printer";
            message = "Print FAILED: {{ states('${dev.printer.taskName}') }}";
          })
        ];
      }
      # ---- maintenance -----------------------------------------------------------
      {
        # MQTT triggers armed before the MQTT integration is up fail with `mqtt_not_setup_cannot_subscribe`
        # and every wall remote is dead until a reload. The latch records that reload, so the late trigger
        # only fires while it is clear and an ordinary Zigbee2MQTT restart cancels nothing.
        id = "mqtt_trigger_recovery";
        alias = "System: re-attach MQTT triggers after startup";
        mode = "single";
        triggers = [
          {
            trigger = "homeassistant";
            event = "start";
          }
        ];
        actions = [
          (setBool mqttTriggersArmed false)
          {
            wait_template = "{{ is_state('${dev.z2m.bridgeState}','on') }}";
            timeout = "00:05:00";
            continue_on_timeout = true;
          }
          {
            "if" = [(template "{{ wait.completed }}")];
            # The reload cancels this very run, so the latch is set before it.
            "then" = [
              {delay.seconds = 5;}
              (setBool mqttTriggersArmed true)
              {action = "automation.reload";}
            ];
            "else" = [(discord "⚠️ Zigbee2MQTT bridge not online 5 min after start; wall remotes may be dead until the bridge reconnects")];
          }
        ];
      }
      {
        id = "mqtt_trigger_recovery_late";
        alias = "System: re-attach MQTT triggers when the bridge returns";
        mode = "single";
        triggers = [
          {
            trigger = "state";
            entity_id = dev.z2m.bridgeState;
            to = "on";
            for = "00:00:30";
          }
        ];
        conditions = [(isOff mqttTriggersArmed)];
        actions = [
          (setBool mqttTriggersArmed true)
          {action = "automation.reload";}
        ];
      }
      {
        id = "zigbee_daily_digest";
        alias = "Zigbee: daily digest";
        triggers = [
          {
            trigger = "time";
            at = "18:00:00";
          }
        ];
        conditions = [(template "{{ states('sensor.zigbee_health_report') | int(0) > 0 }}")];
        actions = [(discord "{{ state_attr('sensor.zigbee_health_report','report') }}")];
      }
      {
        id = "zigbee_monthly_health";
        alias = "Zigbee: monthly health report";
        triggers = [
          {
            trigger = "time";
            at = "18:05:00";
          }
        ];
        conditions = [(template "{{ now().day == 1 }}")];
        actions = [(discord "📡 Monthly Zigbee report\n{{ state_attr('sensor.zigbee_health_report','report') }}\nBatteries: {{ (state_attr('sensor.zigbee_low_batteries','all') or []) | join(', ') }}")];
      }
      {
        # One message per change of the set, not per entity: a broker outage flips everything at once.
        id = "zigbee_device_unavailable";
        alias = "Zigbee: device unavailable";
        triggers = [
          {
            trigger = "state";
            entity_id = "sensor.zigbee_unavailable";
            for = "00:30:00";
          }
        ];
        conditions = [(template "{{ trigger.to_state.state | int(0) > trigger.from_state.state | int(0) }}")];
        actions = [(discord "⚠️ Unreachable Zigbee devices: {{ state_attr('sensor.zigbee_unavailable','items') | join(', ') }}. Battery, or switched off at the wall?")];
      }
    ];

  script = {
    entrance_animation = {
      alias = "Entrance: chase animation";
      mode = "single";
      fields.brightness_pct = {
        description = "Level to end at";
        default = 100;
      };
      sequence =
        lib.concatMap (l: [
          (turnOn (light l) {brightness_pct = "{{ brightness_pct | default(100) }}";})
          {delay.milliseconds = 250;}
        ])
        dev.rooms.entrance.lights;
    };
    goodnight = {
      alias = "Goodnight";
      mode = "single";
      sequence = [
        (turnOff (group "all"))
        (plugOff [bedroomFan kitchenFan])
        pausePlayers
        (setBool sleepMode true)
      ];
    };
  };

  inherit zigbeeWatch;
}
