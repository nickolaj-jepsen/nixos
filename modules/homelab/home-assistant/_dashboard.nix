# Rendered to ui-lovelace.yaml, the "Home" panel.
{
  lib,
  dev,
}: let
  inherit (dev) light switch battery group;
  tile = entity: extra: {type = "tile";} // {inherit entity;} // extra;
  roomSection = key: room: {
    type = "grid";
    cards =
      [
        {
          type = "heading";
          heading = room.name;
          heading_style = "title";
        }
        (tile (group key) {
          name = "All";
          features = [{type = "light-brightness";}];
        })
      ]
      ++ map (l: tile (light l) {name = lib.removePrefix "${lib.head (lib.splitString " - " l)} - " l;}) room.lights;
  };
in {
  title = "Home";
  views = [
    {
      title = "Home";
      path = "home";
      type = "sections";
      max_columns = 3;
      sections =
        [
          {
            type = "grid";
            cards = [
              {
                type = "heading";
                heading = "Modes";
                heading_style = "title";
              }
              (tile "input_boolean.sleep_mode" {name = "Sleep mode";})
              (tile "input_boolean.guest_mode" {name = "Guest mode";})
              (tile "person.nickolaj_jepsen" {name = "Nickolaj";})
              (tile (group "all") {
                name = "All lights";
                features = [{type = "toggle";}];
              })
            ];
          }
        ]
        ++ lib.mapAttrsToList roomSection dev.rooms
        ++ [
          {
            type = "grid";
            cards = [
              {
                type = "heading";
                heading = "Fans and outlets";
                heading_style = "title";
              }
              (tile (switch dev.outlets.bedroomFan) {name = "Bedroom fan";})
              (tile (switch dev.outlets.kitchenFan) {name = "Kitchen fan";})
              (tile (switch dev.outlets.officeAudio) {name = "Office speakers";})
            ];
          }
          {
            type = "grid";
            cards = [
              {
                type = "heading";
                heading = "Today";
                heading_style = "title";
              }
              {
                type = "weather-forecast";
                entity = "weather.forecast_home";
                forecast_type = "daily";
              }
              (tile "sensor.sleep_as_android_next_alarm" {name = "Next alarm";})
            ];
          }
        ];
    }
    {
      title = "Devices";
      path = "devices";
      type = "sections";
      max_columns = 2;
      sections = [
        {
          type = "grid";
          cards = [
            {
              type = "heading";
              heading = "Batteries";
              heading_style = "title";
            }
            {
              type = "entities";
              entities =
                lib.mapAttrsToList (n: d: {
                  entity = battery n;
                  name = "${n} (${d.cells})";
                })
                dev.batteryDevices;
            }
            {
              type = "history-graph";
              title = "Last 30 days";
              hours_to_show = 720;
              entities = map (e: {entity = e;}) dev.batteryEntities;
            }
          ];
        }
        {
          type = "grid";
          cards = [
            {
              type = "heading";
              heading = "Health";
              heading_style = "title";
            }
            (tile "binary_sensor.zigbee2mqtt_bridge_connection_state" {name = "Zigbee bridge";})
            (tile "sensor.zigbee_unavailable" {name = "Unreachable devices";})
            (tile "sensor.zigbee_updates" {name = "Firmware updates";})
            (tile "sensor.zigbee_weak_links" {
              name = "Weak links";
              state_content = ["state" "reporting"];
            })
            {
              type = "markdown";
              content = "{{ state_attr('sensor.zigbee_health_report','report') }}";
            }
          ];
        }
      ];
    }
  ];
}
