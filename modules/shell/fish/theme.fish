# Colorscheme: use terminal colors
set -U fish_color_normal normal
set -U fish_color_command blue
set -U fish_color_quote yellow
set -U fish_color_redirection cyan --bold
set -U fish_color_end green
set -U fish_color_error brred
set -U fish_color_param cyan
set -U fish_color_comment red
set -U fish_color_match --background=brblue
set -U fish_color_selection white --bold --background=brblack
set -U fish_color_search_match bryellow --background=brblack
set -U fish_color_history_current --bold
set -U fish_color_operator brcyan
set -U fish_color_escape brcyan
set -U fish_color_cwd green
set -U fish_color_cwd_root red
set -U fish_color_valid_path --underline
set -U fish_color_autosuggestion brblack
set -U fish_color_user brgreen
set -U fish_color_host normal
set -U fish_color_cancel --reverse
set -U fish_pager_color_prefix normal --bold --underline
set -U fish_pager_color_progress brwhite --background=cyan
set -U fish_pager_color_completion normal
set -U fish_pager_color_description yellow --italics
set -U fish_pager_color_selected_background --reverse
set -U fish_pager_color_selected_description
set -U fish_pager_color_selected_completion
set -U fish_pager_color_secondary_completion
set -U fish_pager_color_secondary_background
set -U fish_color_keyword
set -U fish_pager_color_selected_prefix
set -U fish_pager_color_background
set -U fish_pager_color_secondary_prefix
set -U fish_pager_color_secondary_description
set -U fish_color_host_remote
set -U fish_color_option

# Bobthefish config
set -g theme_date_timezone Europe/Copenhagen
set -g theme_date_format "+%a %H:%M"
set -g theme_nerd_fonts yes
set -g theme_color_scheme terminal
set -g theme_display_user ssh
