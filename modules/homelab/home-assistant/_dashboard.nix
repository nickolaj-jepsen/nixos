# Rendered to ui-lovelace.yaml, the "Home" panel.
{
  lib,
  dev,
}: let
  inherit (dev) light switch battery group helpers;
  tile = entity: extra: {type = "tile";} // {inherit entity;} // extra;
  # `visibility` hides the whole section; several only exist while something is happening.
  section = {
    name,
    badges ? [],
    visibility ? [],
  }: cards: let
    heading =
      {
        type = "heading";
        heading = name;
        heading_style = "title";
      }
      // lib.optionalAttrs (badges != []) {inherit badges;};
  in
    {
      type = "grid";
      cards = [heading] ++ cards;
    }
    // lib.optionalAttrs (visibility != []) {inherit visibility;};

  when = entity: state: {
    condition = "state";
    inherit entity state;
  };
  unless = entity: state_not: {
    condition = "state";
    inherit entity state_not;
  };
  over = entity: above: {
    condition = "numeric_state";
    inherit entity above;
  };
  anyOf = conditions: {
    condition = "or";
    inherit conditions;
  };
  countBadge = entity: color: {
    type = "entity";
    inherit entity color;
    show_state = true;
    visibility = [(over entity 0)];
  };

  groupTile = key: name:
    tile (group key) {
      inherit name;
      features_position = "inline";
      features =
        [{type = "light-brightness";}]
        ++ lib.optional dev.rooms.${key}.colorTemp {type = "light-color-temp";};
    };
  roomSection = key: room:
    section {inherit (room) name;} (
      [(groupTile key "All")]
      ++ map (l: tile (light l) {name = lib.removePrefix "${lib.head (lib.splitString " - " l)} - " l;}) room.lights
    );

  unknownStates = ["unknown" "unavailable"];
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
          (section {
              name = "Modes";
              badges = [
                (countBadge "sensor.zigbee_unavailable" "red")
                (countBadge "sensor.zigbee_low_batteries" "orange")
              ];
            } [
              {
                type = "shortcut";
                label = "Goodnight";
                icon = "mdi:weather-night";
                tap_action = {
                  action = "perform-action";
                  perform_action = "script.goodnight";
                };
              }
              {
                type = "shortcut";
                label = "Devices";
                icon = "mdi:devices";
                tap_action = {
                  action = "navigate";
                  navigation_path = "/nixos-lovelace/devices";
                };
              }
              (tile helpers.sleepMode {name = "Sleep mode";})
              (tile helpers.guestMode {name = "Guest mode";})
              (tile dev.person {name = "Nickolaj";})
              (tile (group "all") {
                name = "All lights";
                features = [{type = "toggle";}];
              })
            ])
          (section {
              name = "Riding";
              visibility = [(when dev.zwift.online "True")];
            } [
              (tile dev.zwift.power {name = "Power";})
              (tile dev.zwift.heartRate {name = "Heart rate";})
              (tile dev.zwift.cadence {name = "Cadence";})
              (tile dev.zwift.speed {name = "Speed";})
              (tile (switch dev.outlets.kitchenFan) {name = "Kitchen fan";})
              (groupTile "living_room" "Living room")
            ])
          (section {
              name = "Now playing";
              visibility = [
                (anyOf [
                  (when dev.jellyfinShield ["playing" "paused"])
                  (when dev.spotify "playing")
                ])
              ];
            } [
              {
                type = "media-control";
                entity = dev.jellyfinShield;
              }
              {
                type = "media-control";
                entity = dev.spotify;
              }
              (tile helpers.watchingManual {name = "Living room held";})
            ])
          (section {
              name = "Alarm";
              visibility = [
                (anyOf [
                  (unless dev.saa.nextAlarm unknownStates)
                  (unless dev.phoneNextAlarm unknownStates)
                ])
              ];
            } [
              (tile dev.saa.nextAlarm {
                name = "Next alarm";
                time_format = "relative";
              })
              (tile dev.phoneNextAlarm {
                name = "Phone alarm";
                time_format = "relative";
              })
              (tile dev.saa.alarmLabel {name = "Label";})
              (tile helpers.sleepMode {name = "Sleep mode";})
            ])
          (section {
              name = "Away";
              visibility = [(when dev.person "not_home")];
            } [
              (tile dev.sensors."Entrance - Door".contact {name = "Front door";})
              (tile helpers.awaySimulation {name = "Away simulation";})
              (groupTile "entrance" "Entrance")
              (groupTile "stairs" "Stairs")
              # time_format only formats timestamps in state_content, so a binary sensor needs last_changed listed.
              (tile dev.sensors."Entrance - Movement sensor".occupancy {
                name = "Entrance motion";
                state_content = ["state" "last_changed"];
                time_format = "relative";
              })
            ])
          (section {
              name = "Printer";
              # finish/failed are resting states the printer holds until the next job.
              visibility = [(unless dev.printer.status (unknownStates ++ ["idle" "offline" "finish" "failed"]))];
            } [
              (tile dev.printer.status {name = "Status";})
              (tile dev.printer.progress {name = "Progress";})
              (tile dev.printer.remainingTime {name = "Remaining";})
              (tile dev.printer.endTime {
                name = "Done at";
                time_format = "relative";
              })
              (tile dev.printer.currentStage {name = "Stage";})
            ])
        ]
        ++ lib.mapAttrsToList roomSection dev.rooms
        ++ [
          (section {name = "Fans and outlets";} [
            (tile (switch dev.outlets.bedroomFan) {name = "Bedroom fan";})
            (tile (switch dev.outlets.kitchenFan) {name = "Kitchen fan";})
            (tile (switch dev.outlets.officeAudio) {name = "Office speakers";})
          ])
          (section {
              name = "Today";
              badges = [
                {
                  type = "entity";
                  entity = dev.meteoalarm;
                  color = "red";
                  show_state = true;
                  visibility = [(when dev.meteoalarm "on")];
                }
              ];
            } [
              (tile dev.weather {
                name = "Weather";
                features = [
                  {
                    type = "temperature-forecast";
                    forecast_type = "daily";
                  }
                  {
                    type = "precipitation-forecast";
                    forecast_type = "daily";
                  }
                ];
              })
            ])
        ];
    }
    {
      title = "Devices";
      path = "devices";
      type = "sections";
      max_columns = 2;
      sections = [
        (section {name = "Batteries";} [
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
        ])
        (section {name = "Health";} [
          (tile dev.z2m.bridgeState {name = "Zigbee bridge";})
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
        ])
        (section {name = "Zigbee";} [
          (tile dev.z2m.permitJoin {
            name = "Permit join";
            features = [{type = "toggle";}];
          })
          (tile dev.z2m.restart {name = "Restart bridge";})
          (tile dev.z2m.health {
            name = "Bridge queue";
            state_content = ["state"];
          })
        ])
        (section {name = "Network";} [
          (tile dev.unifi.firmware {
            name = "Dream Machine firmware";
            features = [{type = "update-actions";}];
          })
          (tile dev.unifi.restart {name = "Restart Dream Machine";})
        ])
      ];
    }
  ];
}
