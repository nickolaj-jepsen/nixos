import { App } from "astal/gtk4";
import main from "./src/main";
import css from "./src/main.scss";

App.start({
  css,
  icons: "./icons",
  main: () => {
    main();
  },
});
