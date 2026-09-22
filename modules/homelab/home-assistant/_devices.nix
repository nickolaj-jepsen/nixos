# Zigbee inventory. Names are the Zigbee2MQTT friendly names: HA entity ids and
# the remotes' action topics derive from them, so a rename touches all of these.
{lib}: rec {
  # Matches HA's slugify of the discovered names.
  slug = s: lib.toLower (lib.replaceStrings [" - " " " "-"] ["_" "_" "_"] s);
  light = n: "light.${slug n}";
  switch = n: "switch.${slug n}";
  battery = n: "sensor.${slug n}_battery";
  update = n: "update.${slug n}";
  actionTopic = n: "zigbee2mqtt/${n}/action";

  # Zigbee groups (ids/names declared in mqtt.nix); one multicast per command.
  groups = {
    office = "Office - Lights";
    stairs = "Stairs - Lights";
    entrance = "Entrance - Lights";
    bathroom = "Bathroom - Lights";
    bedroom = "Bedroom - Lights";
    living_room = "Living room - Lights";
    all = "All lights";
  };
  group = room: light groups.${room};

  rooms = {
    office = {
      name = "Office";
      lights = ["Office - Ceiling light 1" "Office - Ceiling light 3" "Office - Ceiling light 4"];
      colorTemp = true;
    };
    stairs = {
      name = "Stairs";
      lights = ["Stairs - Ceiling light 1" "Stairs - Ceiling light 2"];
      colorTemp = true;
    };
    entrance = {
      name = "Entrance";
      lights = [
        "Entrance - Ceiling light 1"
        "Entrance - Ceiling light 2"
        "Entrance - Ceiling light 3"
        "Entrance - Ceiling light 4"
        "Entrance - Ceiling light 5"
      ];
      colorTemp = false;
    };
    bathroom = {
      name = "Bathroom";
      lights = ["Bathroom - Ceiling light 1" "Bathroom - Ceiling light 2" "Bathroom - Ceiling light 3"];
      colorTemp = false;
    };
    bedroom = {
      name = "Bedroom";
      lights = ["Bedroom - Ceiling light" "Bedroom - Desk lamp"];
      colorTemp = false; # STOFTMOLN is brightness-only; the desk lamp has colour temp
    };
    living_room = {
      name = "Living room";
      lights = ["Kitchen - Ceiling light" "Kitchen - Sofa light"];
      colorTemp = true;
    };
  };
  allLights = lib.concatMap (r: r.lights) (lib.attrValues rooms);

  # Powered off at the wall for long stretches: excluded from unavailable alerts.
  wallSwitched = ["Bedroom - Desk lamp" "Kitchen - Sofa light"];

  outlets = {
    bedroomFan = "Bedroom - Fan";
    kitchenFan = "Kitchen - Fan";
    officeAudio = "Office - Audio";
  };

  remotes = {
    "Office - Switch" = {
      cells = "2×AAA";
      threshold = 20;
    };
    "Bathroom - Switch" = {
      cells = "1×AAA";
      threshold = 20;
    };
    "Bedroom - Switch" = {
      cells = "CR2032";
      threshold = 30;
    };
    "Bedroom - Bed switch" = {
      cells = "CR2032";
      threshold = 30;
    };
    "Kitchen - Switch" = {
      cells = "CR2032";
      threshold = 30;
    };
    "Stairs - Switch top" = {
      cells = "CR2032";
      threshold = 30;
    };
    "Stairs - Switch bottom" = {
      cells = "CR2032";
      threshold = 30;
    };
  };
  sensors = {
    "Stairs - Movement sensor" = {
      cells = "2×CR2032";
      threshold = 25;
      occupancy = "binary_sensor.stairs_movement_sensor_occupancy";
    };
    "Entrance - Movement sensor" = {
      cells = "2×CR2032";
      threshold = 25;
      occupancy = "binary_sensor.entrance_movement_sensor_occupancy";
    };
    "Entrance - Door" = {
      cells = "1×AAA";
      threshold = 20;
      contact = "binary_sensor.entrance_door_contact";
    };
  };
  batteryDevices = remotes // sensors;

  # `unavailable` means gone: routers are pinged every 10 min, battery devices time out after 25 h.
  routerEntities =
    map light (lib.subtractLists wallSwitched allLights)
    ++ map switch (lib.attrValues outlets);
  batteryEntities = lib.mapAttrsToList (n: _: battery n) batteryDevices;
  updateEntities = map update (allLights ++ lib.attrValues outlets ++ lib.attrNames batteryDevices);
  # Adaptive Lighting profiles (hass.nix). The first four rooms keep sleep-mode switch
  # ids set by hand in the entity registry; AL composes a fresh one from the device
  # name plus "Sleep Mode". Verify on the device page after adding a room.
  alRooms = ["office" "stairs" "living_room" "bedroom" "entrance" "bathroom"];
  alLegacySleepIds = ["office" "stairs" "living_room" "bedroom"];
  alSwitch = r: "switch.adaptive_lighting_${r}";
  alSleep = r:
    if lib.elem r alLegacySleepIds
    then "switch.adaptive_lighting_sleep_mode_${r}"
    else "switch.adaptive_lighting_${r}_sleep_mode";

  # Discovered disabled (diagnostic); enabled once in the entity registry.
  linkquality = n: "sensor.${slug n}_linkquality";
  linkqualityEntities = map linkquality (allLights ++ lib.attrValues outlets ++ lib.attrNames batteryDevices);

  # zwift_hass 4.x names entities "Zwift <profile name> <sensor>"; verify on the device page after the config flow.
  zwift = {
    online = "sensor.zwift_nickolaj_jepsen_online";
    powerZone = "sensor.zwift_nickolaj_jepsen_power_zone";
    power = "sensor.zwift_nickolaj_jepsen_power";
    heartRate = "sensor.zwift_nickolaj_jepsen_heart_rate";
    cadence = "sensor.zwift_nickolaj_jepsen_cadence";
    speed = "sensor.zwift_nickolaj_jepsen_speed";
  };

  # Config-flow integrations: ids derive from device names in the UI; verify on the device page, correct here only.
  person = "person.nickolaj_jepsen";
  # The entity service takes no `data`; channels and actions need the legacy action.
  phoneNotifyAction = "notify.mobile_app_pixel_8_pro";
  phoneNextAlarm = "sensor.pixel_8_pro_next_alarm"; # enabled under Manage sensors in the app
  pcTracker = "device_tracker.nickolaj"; # DESKTOP-I059SU2 by cable (UniFi); the sim PC, not a person
  spotify = "media_player.spotify_nickolaj_jepsen";
  # Jellyfin names the player after the session's DeviceName; the Shield's is expected to slug to this.
  jellyfinShield = "media_player.shield_android_tv";
  weather = "weather.forecast_home";
  meteoalarm = "binary_sensor.meteoalarm";
  saa = {
    alarmEvent = "event.sleep_as_android_alarm_clock";
    nextAlarm = "sensor.sleep_as_android_next_alarm";
    alarmLabel = "sensor.sleep_as_android_alarm_label";
  };
  # ha-bambulab names the device <model>_<serial>, not after the printer's name in the cloud account.
  printer = let
    s = k: "sensor.a1_03919c470201008_${k}";
  in {
    status = s "print_status"; # idle | prepare | running | pause | finish | failed | offline
    progress = s "print_progress";
    remainingTime = s "remaining_time";
    currentStage = s "current_stage";
    endTime = s "end_time";
    taskName = s "task_name";
  };
  z2m = {
    bridgeState = "binary_sensor.zigbee2mqtt_bridge_connection_state";
    permitJoin = "switch.zigbee2mqtt_bridge_permit_join";
    restart = "button.zigbee2mqtt_bridge_restart";
    health = "sensor.zigbee2mqtt_health"; # mqtt sensor declared in hass.nix from bridge/health
  };
  unifi = {
    firmware = "update.dream_machine_firmware";
    restart = "button.dream_machine_restart";
  };
  helpers = {
    sleepMode = "input_boolean.sleep_mode";
    guestMode = "input_boolean.guest_mode";
    stairsManual = "input_boolean.stairs_manual";
    entranceManual = "input_boolean.entrance_manual";
    zwiftRide = "input_boolean.zwift_ride"; # set by ride mode; the fan-off path only acts while it is on
    watchingManual = "input_boolean.watching_manual"; # a Kitchen switch press during playback owns the room for the session
    mqttTriggersArmed = "input_boolean.mqtt_triggers_armed"; # cleared at start, set after a successful reload
    awaySimulation = "input_boolean.away_simulation"; # on after 24 h away; dashboard + the evening pattern
  };
}
