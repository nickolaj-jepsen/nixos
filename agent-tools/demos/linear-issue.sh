# shellcheck disable=SC2034  # read by record.sh, which sources this
# linear-issue's demo, sourced by record.sh: /linear drafts an issue, the title is rewritten,
# Esc hides the draft to its chip and 8 reopens it with the edit kept.
#
# Nothing is filed: no step presses Create or Discard, Linear's write tools stay unapproved
# (a stray press would stop at a permission prompt), and record.sh drops the recording if the
# log shows one was called. The Team list is never opened: it would publish every team name.

# The claude.ai Linear connector, from the full profile; only the reads drafting makes are approved.
L=mcp__claude_ai_Linear__
TUI_ARGS=(--full)
CLAUDE_ARGS=(--allowedTools "${L}get_user,${L}list_teams,${L}list_issue_statuses,${L}list_issue_labels,${L}list_projects,${L}list_issues")
READY_LOG='claude.ai Linear": Successfully connected'
FORBIDDEN_LOG='Linear__save_'

demo() {
  type_slow '/linear the sync worker ignores Retry-After headers when it backs off after a 429'
  pause 1
  press Enter
  wait_for 'Create & open' 180
  pause 2.5
  # The pane opens with the focus in the title. A plugin Input takes no Ctrl+U (that clears
  # the prompt), so empty it key by key, at a pace its round trips keep up with.
  repeat 85 BSpace 0.06
  wait_for 'Title: +⏎ submit'
  type_slow "Honor Retry-After in the sync worker's 429 backoff" 0.1
  pause 1
  # The first Esc leaves the field, the second hides the pane. Not blindly twice: two at an
  # empty prompt open the rewind menu.
  press Escape
  pause 1
  screen | grep -q 'Linear draft: ' || press Escape
  wait_for 'Linear draft: .*8: Open'
  pause 1.5
  press 8
  wait_for 'Create & open'
  pause 2.5
}
