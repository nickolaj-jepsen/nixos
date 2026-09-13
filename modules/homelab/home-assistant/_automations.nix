# Multi-bulb targets are always Zigbee group entities: one multicast, no per-bulb timeout.
{
  lib,
  dev,
}: let
  inherit (dev) light switch group slug actionTopic;
  person = "person.nickolaj_jepsen";
  sleepMode = "input_boolean.sleep_mode";
  guestMode = "input_boolean.guest_mode";
  manual = room: "input_boolean.${room}_manual";
  alarmEvent = "event.sleep_as_android_alarm_clock";
  nextAlarm = "sensor.sleep_as_android_next_alarm";
  spotify = "media_player.spotify_nickolaj_jepsen";
  bedroomCeiling = light "Bedroom - Ceiling light";
  deskLamp = light "Bedroom - Desk lamp";
  bedroomFan = switch dev.outlets.bedroomFan;
  kitchenFan = switch dev.outlets.kitchenFan;
  inherit (dev) alSwitch alSleep alRooms;

  # Night: sleep mode, or late hours as a fallback when goodnight was never pressed.
  isNight = "is_state('${sleepMode}','on') or now().hour >= 23 or now().hour < 6";
  nightLevel = "{{ 15 if (${isNight}) else 100 }}";
  # Dark: sun low, or the sensor's illuminance flag off (= below its threshold).
  dark = flag: {
    condition = "template";
    value_template = "{{ state_attr('sun.sun','elevation') | float(0) < 3 or is_state('${flag}','off') }}";
  };
  sunDown = {
    condition = "numeric_state";
    entity_id = "sun.sun";
    attribute = "elevation";
    below = 3;
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
  setBool = e: on: {
    action = "input_boolean.turn_${
      if on
      then "on"
      else "off"
    }";
    target.entity_id = e;
  };
  discord = message: {
    action = "rest_command.discord";
    data.message = message;
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
        choose =
          lib.mapAttrsToList (action: sequence: {
            conditions = [
              {
                condition = "trigger";
                id = action;
              }
            ];
            inherit sequence;
          })
          actions;
      }
    ];
  };

  motion = {
    room,
    sensor,
    onActions,
    offTarget,
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
      conditions = [(dark sensor.dark) (isOff offTarget)];
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
          for = "00:02:00";
        }
      ];
      conditions = [(isOff (manual room)) (isOff guestMode)];
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

  zigbeeWatch = dev.routerEntities ++ dev.batteryEntities;
in {
  automation =
    [
      # ---- remotes -------------------------------------------------------------
      (remote "Office - Switch" {
        "on" = [
          {
            "if" = [(isOn (group "office"))];
            "then" = [(step (group "office") 20)];
            "else" = [(turnOn (group "office") {})];
          }
        ];
        "off" = [(step (group "office") (-20))];
        brightness_move_up = [(turnOn (group "office") {brightness_pct = 100;})];
        brightness_move_down = [(turnOff (group "office"))];
      })
      (remote "Bedroom - Switch" {
        "on" = [(turnOn (group "bedroom") {})];
        "off" = [(turnOff (group "bedroom"))];
      })
      (remote "Kitchen - Switch" {
        "on" = [(turnOn (group "living_room") {})];
        "off" = [(turnOff (group "living_room"))];
      })
      (remote "Stairs - Switch top" {
        "on" = [(setBool (manual "stairs") true) (turnOn (group "stairs") {})];
        "off" = [(turnOff (group "stairs")) (turnOff (group "entrance")) (turnOff (group "living_room"))];
      })
      (remote "Stairs - Switch bottom" {
        "on" = [
          (setBool (manual "stairs") true)
          (setBool (manual "entrance") true)
          (turnOn (group "stairs") {})
          (turnOn (group "entrance") {brightness_pct = nightLevel;})
        ];
        "off" = [(turnOff (group "stairs")) (turnOff (group "entrance"))];
      })
      (remote "Bedroom - Bed switch" {
        "on" = [
          (turnOn deskLamp {
            brightness_pct = 10;
            color_temp_kelvin = 2200;
          })
          {
            action = "switch.turn_on";
            target.entity_id = bedroomFan;
          }
        ];
        brightness_move_up = [(turnOn (group "bedroom") {})];
        "off" = [
          (turnOff (group "all"))
          {
            action = "switch.turn_off";
            target.entity_id = [bedroomFan kitchenFan];
          }
        ];
        brightness_move_down = [{action = "script.goodnight";}];
      })
      (remote "Bathroom - Switch" {
        "on" = [(turnOn (group "bathroom") {brightness_pct = nightLevel;})];
        "off" = [(turnOff (group "bathroom"))];
        brightness_move_up = [(step (group "bathroom") 20)];
        brightness_move_down = [(step (group "bathroom") (-20))];
      })
    ]
    # ---- motion ----------------------------------------------------------------
    ++ (motion {
      room = "stairs";
      sensor = dev.sensors."Stairs - Movement sensor";
      # Explicit level avoids a flash at the last level before Adaptive Lighting adapts.
      onActions = [(turnOn (group "stairs") {brightness_pct = nightLevel;})];
      offTarget = group "stairs";
    })
    ++ (motion {
      room = "entrance";
      sensor = dev.sensors."Entrance - Movement sensor";
      onActions = [
        {
          action = "script.entrance_animation";
          data.brightness_pct = nightLevel;
        }
      ];
      offTarget = group "entrance";
    })
    ++ [
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
          }
        ];
        conditions = [(isOff guestMode)];
        actions = [
          (turnOff (group "all"))
          {
            action = "switch.turn_off";
            target.entity_id = [bedroomFan kitchenFan];
          }
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
            entity_id = dev.sensors."Entrance - Door".contact;
            to = "on";
          }
        ];
        conditions = [
          sunDown
          (isOff (group "entrance"))
          (isOff sleepMode)
          {
            condition = "template";
            value_template = "{{ is_state('${person}', 'not_home') or (now() - states['${person}'].last_changed).total_seconds() < 600 }}";
          }
        ];
        actions = [
          (turnOn (group "entrance") {brightness_pct = nightLevel;})
          (turnOn (group "stairs") {brightness_pct = nightLevel;})
        ];
      }
      # ---- door ------------------------------------------------------------------
      {
        id = "door_left_open";
        alias = "Door: left open";
        triggers = [
          {
            trigger = "state";
            entity_id = dev.sensors."Entrance - Door".contact;
            to = "on";
            for = "00:10:00";
          }
        ];
        actions = [(discord "🚪 The entrance door has been open for 10 minutes.")];
      }
      {
        id = "door_opened_while_away";
        alias = "Door: opened while away";
        triggers = [
          {
            trigger = "state";
            entity_id = dev.sensors."Entrance - Door".contact;
            to = "on";
          }
        ];
        conditions = [
          {
            condition = "state";
            entity_id = person;
            state = "not_home";
          }
        ];
        actions = [(discord "🚪 The entrance door opened at {{ now().strftime('%H:%M') }} while nobody is home.")];
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
        actions = [
          {
            action = "switch.turn_{{ trigger.to_state.state }}";
            target.entity_id = map alSleep alRooms;
          }
        ];
      }
      {
        # Daily reset of every latch (sleep mode, motion overrides, alarm-ramp manual flag).
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
          {
            action = "adaptive_lighting.set_manual_control";
            data = {
              entity_id = alSwitch "bedroom";
              lights = [bedroomCeiling];
              manual_control = false;
            };
          }
        ];
      }
      # ---- alarm (Sleep as Android, core webhook integration) --------------------
      {
        id = "alarm_events";
        alias = "Alarm: Sleep as Android events";
        mode = "queued";
        triggers = [
          {
            trigger = "state";
            entity_id = alarmEvent;
          }
        ];
        conditions = [
          {
            # The state is the event timestamp, so every event fires; skip (re)adds and stale restores.
            condition = "template";
            value_template = "{{ trigger.from_state is not none and trigger.to_state.state not in ['unknown','unavailable'] and (now() - as_datetime(trigger.to_state.state)).total_seconds() < 120 }}";
          }
        ];
        actions = [
          {
            choose = [
              {
                conditions = [
                  {
                    condition = "template";
                    value_template = "{{ trigger.to_state.attributes.event_type == 'alert_start' }}";
                  }
                ];
                sequence = [
                  (setBool sleepMode false)
                  {
                    action = "adaptive_lighting.set_manual_control";
                    data = {
                      entity_id = alSwitch "bedroom";
                      lights = [bedroomCeiling];
                      manual_control = false;
                    };
                  }
                  (turnOn bedroomCeiling {})
                  (turnOn (group "stairs") {})
                ];
              }
              {
                conditions = [
                  {
                    condition = "template";
                    value_template = "{{ trigger.to_state.attributes.event_type == 'alert_dismiss' }}";
                  }
                ];
                sequence = [(setBool sleepMode false)];
              }
            ];
          }
        ];
      }
      {
        id = "alarm_ramp";
        alias = "Alarm: bedroom ramps up before the alarm";
        mode = "single";
        triggers = [
          {
            trigger = "time";
            at = {
              entity_id = nextAlarm;
              offset = "-00:10:00";
            };
          }
        ];
        conditions = [
          {
            condition = "state";
            entity_id = person;
            state = "home";
          }
        ];
        actions = [
          {
            action = "adaptive_lighting.set_manual_control";
            data = {
              entity_id = alSwitch "bedroom";
              lights = [bedroomCeiling];
              manual_control = true;
            };
          }
          (turnOn bedroomCeiling {brightness_pct = 1;})
          (turnOn bedroomCeiling {
            brightness_pct = 60;
            transition = 600;
          })
        ];
      }
      # ---- Zwift -----------------------------------------------------------------
      {
        id = "zwift_fan_on";
        alias = "Zwift: fan on when riding";
        triggers = [
          {
            trigger = "state";
            entity_id = dev.zwiftOnline;
            to = "True";
          }
        ];
        conditions = [
          {
            condition = "state";
            entity_id = person;
            state = "home";
          }
        ];
        actions = [
          {
            action = "switch.turn_on";
            target.entity_id = kitchenFan;
          }
        ];
      }
      {
        id = "zwift_fan_off";
        alias = "Zwift: fan off after the ride";
        triggers = [
          {
            trigger = "state";
            entity_id = dev.zwiftOnline;
            from = "True";
            to = "False";
            for = "00:10:00";
          }
        ];
        actions = [
          {
            action = "switch.turn_off";
            target.entity_id = kitchenFan;
          }
        ];
      }
      # ---- maintenance -----------------------------------------------------------
      {
        # Triggers are armed once, right after the start event, with no retry: an MQTT
        # trigger armed before the MQTT integration is loaded fails with
        # `mqtt_not_setup_cannot_subscribe` and every wall remote stays dead until a reload
        # (all seven, on the first start before the MQTT entry existed; a broker that is
        # unreachable at start does the same). Reloading once the bridge is live re-arms them.
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
          {
            wait_template = "{{ is_state('binary_sensor.zigbee2mqtt_bridge_connection_state','on') }}";
            timeout = "00:05:00";
            continue_on_timeout = false;
          }
          {delay.seconds = 5;}
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
        conditions = [
          {
            condition = "template";
            value_template = "{{ states('sensor.zigbee_health_report') | int(0) > 0 }}";
          }
        ];
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
        conditions = [
          {
            condition = "template";
            value_template = "{{ now().day == 1 }}";
          }
        ];
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
        conditions = [
          {
            condition = "template";
            value_template = "{{ trigger.to_state.state | int(0) > trigger.from_state.state | int(0) }}";
          }
        ];
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
        {
          action = "switch.turn_off";
          target.entity_id = [bedroomFan kitchenFan];
        }
        {
          action = "media_player.media_pause";
          target.entity_id = spotify;
          continue_on_error = true;
        }
        (setBool sleepMode true)
      ];
    };
  };

  inherit zigbeeWatch;
}
