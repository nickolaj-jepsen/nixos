{
  style = ''
    @define-color fg #DAD8CE;
    @define-color fg-alt #B7B5AC;
    @define-color bg #1C1B1A;
    @define-color bg-alt #282726;
    @define-color accent #CF6A4C;
    @define-color muted #878580;
    @define-color error #D14D41;

    #window,
    #box,
    #aiScroll,
    #aiList,
    #search,
    #password,
    #input,
    #prompt,
    #clear,
    #typeahead,
    #list,
    child,
    scrollbar,
    slider,
    #item,
    #text,
    #label,
    #bar,
    #sub,
    #activationlabel {
      all: unset;
      font-family: Hack;
    }

    #cfgerr {
      background: rgba(255, 0, 0, 0.4);
      margin-top: 20px;
      padding: 8px;
      font-size: 14px;
      font-family: "Hack Nerd Font";
    }

    #window {
      color: @fg;
    }

    #box {
      border-radius: 8px;
      background: @bg;
      padding: 8px;
      border: 2px solid @accent;
    }

    #search {
      background: @bg-alt;
      padding: 8px;
    }

    #prompt {
      margin-left: 4px;
      margin-right: 12px;
      color: @fg;
      opacity: 0.2;
    }

    #clear {
      color: @fg;
    @define-color fg #DAD8CE;
    @define-color fg-alt #B7B5AC;
    @define-color bg #1C1B1A;
    @define-color bg-alt #282726;
    @define-color accent #CF6A4C;
    @define-color muted #878580;
    @define-color error #D14D41;

    #window,
    #box,
    #aiScroll,
    #aiList,
    #search,
    #password,
    #input,
    #prompt,
    #clear,
    #typeahead,
    #list,
    child,
    scrollbar,
    slider,
    #item,
    #text,
    #label,
    #bar,
    #sub,
    #activationlabel {
      all: unset;
      font-family: Hack;
    }

    #cfgerr {
      background: rgba(255, 0, 0, 0.4);
      margin-top: 20px;
      padding: 8px;
      font-size: 14px;
      font-family: "Hack Nerd Font";
    }

    #window {
      color: @fg;
    }

    #box {
      border-radius: 8px;
      background: @bg;
      padding: 8px;
      border: 2px solid @accent;
    }

    #search {
      background: @bg-alt;
      padding: 8px;
    }

    #prompt {
      margin-left: 4px;
      margin-right: 12px;
      color: @fg;
      opacity: 0.2;
    }

    #clear {
      color: @fg;
      opacity: 0.8;
    }

    #password,
    #input,
    #typeahead {
      border-radius: 2px;
    }

    #input {
      background: none;
    }

    #password {
    }

    #spinner {
      padding: 8px;
    }

    #typeahead {
      color: @fg;
      opacity: 0.8;
    }

    #input placeholder {
      opacity: 0.5;
    }

    #list {
    }

    child {
      padding: 8px;
      border-radius: 2px;
    }

    child:selected,
    child:hover {
      background: alpha(@accent, 0.4);
    }

    #item {
    }

    #icon {
      margin-right: 8px;
    }

    #text {
    }

    #label {
      font-weight: 500;
    }

    #sub {
      opacity: 0.5;
      font-size: 0.8em;
    }

    #activationlabel {
    }

    #bar {
    }

    .barentry {
    }

    .activation #activationlabel {
    }

    .activation #text,
    .activation #icon,
    .activation #search {
      opacity: 0.5;
    }

    .aiItem {
      padding: 10px;
      border-radius: 2px;
      color: @fg;
      background: @bg;
    }

    .aiItem.user {
      padding-left: 0;
      padding-right: 0;
    }

    .aiItem.assistant {
      background: @bg-alt;
    }

      opacity: 0.8;
    }

    #password,
    #input,
    #typeahead {
      border-radius: 2px;
    }

    #input {
      background: none;
    }

    #password {
    }

    #spinner {
      padding: 8px;
    }

    #typeahead {
      color: @fg;
      opacity: 0.8;
    }

    #input placeholder {
      opacity: 0.5;
    }

    #list {
    }

    child {
      padding: 8px;
      border-radius: 2px;
    }

    child:selected,
    child:hover {
      background: alpha(@accent, 0.4);
    }

    #item {
    }

    #icon {
      margin-right: 8px;
    }

    #text {
    }

    #label {
      font-weight: 500;
    }

    #sub {
      opacity: 0.5;
      font-size: 0.8em;
    }

    #activationlabel {
    }

    #bar {
    }

    .barentry {
    }

    .activation #activationlabel {
    }

    .activation #text,
    .activation #icon,
    .activation #search {
      opacity: 0.5;
    }

    .aiItem {
      padding: 10px;
      border-radius: 2px;
      color: @fg;
      background: @bg;
    }

    .aiItem.user {
      padding-left: 0;
      padding-right: 0;
    }

    .aiItem.assistant {
      background: @bg-alt;
    }
  '';
  layout = {
    ui = {
      anchors = {
        bottom = true;
        left = true;
        right = true;
        top = true;
      };
      window = {
        h_align = "fill";
        v_align = "fill";
        box = {
          h_align = "center";
          v_align = "center";
          width = 800;
          height = 600;
          bar = {
            orientation = "horizontal";
            position = "end";
            entry = {
              h_align = "fill";
              h_expand = true;
              icon = {
                h_align = "center";
                h_expand = true;
                pixel_size = 24;
                theme = "";
              };
            };
          };
          ai_scroll = {
            name = "aiScroll";
            h_align = "fill";
            v_align = "fill";
            margins = {
              top = 8;
            };
            list = {
              name = "aiList";
              orientation = "vertical";
              width = 400;
              spacing = 10;
              item = {
                name = "aiItem";
                h_align = "fill";
                v_align = "fill";
                x_align = 0;
                y_align = 0;
                wrap = true;
              };
            };
          };
          scroll = {
            v_expand = true;
            v_align = "fill";
            list = {
              v_expand = true;
              h_expand = true;
              h_align = "fill";
              v_align = "fill";
              item = {
                activation_label = {
                  h_align = "fill";
                  v_align = "fill";
                  width = 20;
                  x_align = 0;
                  y_align = 0;
                };
                icon = {
                  pixel_size = 26;
                  theme = "";
                };
              };
              margins = {
                top = 8;
              };
            };
          };
          search = {
            h_expand = false;
            v_expand = false;
            prompt = {
              name = "prompt";
              icon = "edit-find";
              theme = "";
              pixel_size = 18;
              h_align = "center";
              v_align = "center";
            };
            clear = {
              name = "clear";
              icon = "edit-clear";
              theme = "";
              pixel_size = 18;
              h_align = "center";
              v_align = "center";
            };
            input = {
              h_align = "fill";
              h_expand = true;
              icons = true;
            };
            spinner = {
              hide = true;
            };
          };
        };
      };
    };
  };
}
