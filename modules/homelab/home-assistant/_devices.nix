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
      model = "STYRBAR";
      cells = "2×AAA";
      threshold = 20;
    };
    "Bathroom - Switch" = {
      model = "RODRET";
      cells = "1×AAA";
      threshold = 20;
    };
    "Bedroom - Switch" = {
      model = "E1743";
      cells = "CR2032";
      threshold = 30;
    };
    "Bedroom - Bed switch" = {
      model = "E1743";
      cells = "CR2032";
      threshold = 30;
    };
    "Kitchen - Switch" = {
      model = "E1743";
      cells = "CR2032";
      threshold = 30;
    };
    "Stairs - Switch top" = {
      model = "E1743";
      cells = "CR2032";
      threshold = 30;
    };
    "Stairs - Switch bottom" = {
      model = "E1743";
      cells = "CR2032";
      threshold = 30;
    };
  };
  sensors = {
    "Stairs - Movement sensor" = {
      cells = "2×CR2032";
      threshold = 25;
      occupancy = "binary_sensor.stairs_movement_sensor_occupancy";
      dark = "binary_sensor.stairs_movement_sensor_illuminance_above_threshold";
    };
    "Entrance - Movement sensor" = {
      cells = "2×CR2032";
      threshold = 25;
      occupancy = "binary_sensor.entrance_movement_sensor_occupancy";
      dark = "binary_sensor.entrance_movement_sensor_illuminance_above_threshold";
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
}
