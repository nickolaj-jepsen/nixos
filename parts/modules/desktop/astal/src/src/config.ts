export default {
  monitor: {
    main: "M27Q",
  },
  notification: {
    ignore: [/^Spotify/],
  },
  tray: {
    ignore: [/spotify/],
  },
} as const;
