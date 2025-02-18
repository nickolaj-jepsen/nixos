import Wp from "gi://AstalWp";
import { Variable, bind } from "astal";
import type { Binding, Subscribable } from "astal/binding";
import { Gtk, type Gdk } from "astal/gtk4";
import { hasIcon } from "../../utils/gtk";
import { Expander, FlowBox, Separator } from "../../widgets";
import { connectDropdown } from "./Dropdown";
import Pango from "gi://Pango?version=1.0";
import { Box } from "astal/gtk4/widget";

interface PlaybackEndpointProps {
  endpoint: Wp.Endpoint;
  visible?: Binding<boolean>;
}

function PlaybackEndpoint({ endpoint, visible }: PlaybackEndpointProps) {
  const name = Variable.derive(
    [bind(endpoint, "description"), bind(endpoint, "name")],
    (description, name) => name || description || "Unknown",
  );

  const defaultable = Variable.derive(
    [bind(endpoint, "is_default"), bind(endpoint, "media_class")],
    (isDefault, mediaClass) =>
      !isDefault &&
      [Wp.MediaClass.AUDIO_MICROPHONE, Wp.MediaClass.AUDIO_SPEAKER].includes(
        mediaClass,
      ),
  );

  return (
    <box
      vertical
      spacing={5}
      hexpand
      onDestroy={() => {
        name.drop();
        defaultable.drop();
      }}
      visible={visible}
    >
      <box spacing={10} hexpand>
        <button
          onButtonPressed={() => {
            endpoint.set_mute(!endpoint.mute);
          }}
        >
          <image iconName={bind(endpoint, "volumeIcon")} pixelSize={16} />
        </button>
        <label
          label={bind(name)}
          maxWidthChars={bind(defaultable).as((x) => (x ? 23 : 28))}
          ellipsize={Pango.EllipsizeMode.END}
          halign={Gtk.Align.START}
          hexpand
        />
        <button
          visible={bind(defaultable)}
          onButtonPressed={() => {
            endpoint.set_is_default(true);
          }}
        >
          <image iconName="star-filled" pixelSize={20} />
        </button>
      </box>
      <box spacing={5} hexpand>
        <slider
          cssClasses={["Slider"]}
          hexpand
          value={bind(endpoint, "volume")}
          onChangeValue={({ value }) => {
            endpoint.set_volume(value);
          }}
        />
        <label
          label={bind(endpoint, "volume").as((v) =>
            `${Math.floor(v * 100)}%`.padStart(4, " "),
          )}
        />
      </box>
    </box>
  );
}

function PlaybackDropdown({ audioDevices }: { audioDevices: Wp.Audio }) {
  return (
    <box
      spacing={10}
      vertical
      widthRequest={300}
      cssClasses={["PlaybackDropdown"]}
    >
      <label label="Default Speaker" halign={Gtk.Align.START} />
      {bind(audioDevices, "default_speaker").as((speaker) => {
        return <PlaybackEndpoint endpoint={speaker} />;
      })}
      <Expander
        label={"All Speakers"}
        visible={bind(audioDevices, "speakers").as(
          (speakers) => speakers.length > 1,
        )}
      >
        <Box spacing={5} vertical marginTop={10}>
          {bind(audioDevices, "speakers").as((speakers) => {
            return speakers.map((speaker) => (
              <PlaybackEndpoint
                endpoint={speaker}
                visible={bind(speaker, "is_default").as((x) => !x)}
              />
            ));
          })}
        </Box>
      </Expander>
      <Separator />
      <label label="Playback streams" halign={Gtk.Align.START} />
      {bind(audioDevices, "streams").as((streams) => {
        if (streams.length === 0) {
          return (
            <label
              label="No playback streams"
              halign={Gtk.Align.START}
              cssClasses={["no-streams"]}
            />
          );
        }

        return streams.map((stream) => <PlaybackEndpoint endpoint={stream} />);
      })}
      <Separator />
      <label label="Default Microphone" halign={Gtk.Align.START} />
      {bind(audioDevices, "default_microphone").as((microphone) => {
        return <PlaybackEndpoint endpoint={microphone} />;
      })}
      <Expander
        label={"All Microphones"}
        visible={bind(audioDevices, "microphones").as(
          (microphones) => microphones.length > 1,
        )}
      >
        <Box spacing={5} vertical marginTop={10}>
          {bind(audioDevices, "microphones").as((microphones) => {
            return microphones.map((microphone) => (
              <PlaybackEndpoint
                endpoint={microphone}
                visible={bind(microphone, "is_default").as((x) => !x)}
              />
            ));
          })}
        </Box>
      </Expander>
      <Separator />
      <label label="Recording streams" halign={Gtk.Align.START} />
      {bind(audioDevices, "recorders").as((streams) => {
        if (streams.length === 0) {
          return (
            <label
              label="No recording streams"
              halign={Gtk.Align.START}
              cssClasses={["no-streams"]}
            />
          );
        }

        return streams.map((stream) => <PlaybackEndpoint endpoint={stream} />);
      })}
    </box>
  );
}

export function Playback({ monitor }: { monitor: Gdk.Monitor }) {
  const audioDevices = Wp.get_default()?.get_audio?.();
  if (!audioDevices) {
    return <label label="No WirePlumber" visible={false} />;
  }
  // const endpoints = new PlaybackEndpoints(WirePlumber);

  // biome-ignore lint/style/noNonNullAssertion: <explanation>
  const speaker = Wp.get_default()?.audio.defaultSpeaker!;
  const volume = Variable.derive(
    [bind(speaker, "volume"), bind(speaker, "mute")],
    (v, m) => {
      return m ? 0 : v;
    },
  );
  const recording = bind(audioDevices, "recorders").as(
    (recorders) => recorders.length > 0,
  );

  return (
    <box
      cssClasses={["Playback"]}
      spacing={15}
      onDestroy={() => {
        volume.drop();
      }}
      setup={(self) => {
        connectDropdown(
          self,
          <PlaybackDropdown audioDevices={audioDevices} />,
          monitor,
        );
      }}
    >
      {bind(audioDevices, "default_speaker").as((speaker) => {
        const volume = Variable.derive(
          [bind(speaker, "volume"), bind(speaker, "mute")],
          (v, m) => {
            return m ? 0 : v;
          },
        );

        return (
          <>
            <slider
              cssClasses={["Slider"]}
              inverted
              hexpand
              onChangeValue={({ value }) => {
                speaker.volume = value;
                speaker.mute = false;
              }}
              value={bind(volume)}
            />
            <box
              spacing={10}
              onButtonPressed={() => {
                speaker.mute = !speaker.mute;
              }}
            >
              <image iconName={bind(speaker, "volumeIcon")} pixelSize={12} />
              <label
                label={bind(volume).as((v) =>
                  `${Math.floor(v * 100)}%`.padStart(4, " "),
                )}
              />
              <image
                iconName={"microphone-custom"}
                cssClasses={["recording"]}
                pixelSize={16}
                widthRequest={18}
                hexpand
                visible={bind(recording)}
              />
            </box>
          </>
        );
      })}
    </box>
  );
}
