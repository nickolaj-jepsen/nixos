/**
 * The git menu: where this branch lives on the web, and the pull request it is
 * waiting on or still needs. Every row is a link or a copy, so the footer never
 * pushes, rebases or creates anything behind a click; a branch with no upstream
 * says so instead of offering to publish itself.
 *
 * The rows keep their verbs and leave the detail to the title and the footer:
 * the repository sits beside the title, the branch is already in the footer, and
 * a row explaining why it cannot run says it in a few words so the menu stays
 * narrow.
 *
 * The menu is built when it opens, from the footer's last git answer plus one
 * remote lookup, and does not change while it is up.
 */
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { copyText, openUrl } from "./apps.ts";
import type { GitSnapshot, GitState } from "./git.ts";
import type { Menu, MenuRow } from "./menu.ts";
import { branchUrl, commitUrl, compareUrl, repositoryUrl, resolveRemote } from "./remote.ts";

const SHORT_SHA = 7;

export const gitMenu = async (
  ctx: ExtensionContext,
  snapshot: GitSnapshot & { state: GitState },
): Promise<Menu> => {
  const { state, pr, prKnown, ghMissing } = snapshot;
  const branch = state.detached ? undefined : (state.branch ?? undefined);
  const { remote, base } = await resolveRemote(ctx.cwd, branch ?? null);

  const copy = (text: string, what: string) => async (inner: ExtensionContext) => {
    await copyText(text);
    inner.ui.notify(`chrome: ${what} copied`, "info");
  };

  const create = (): MenuRow => {
    const label =
      pr && (pr.state === "merged" || pr.state === "closed")
        ? "Create new pull request"
        : "Create pull request";
    const blocked = (() => {
      if (!remote) return "no supported remote";
      if (remote.forge !== "github") return "GitHub only";
      if (!branch) return "detached HEAD";
      if (pr?.state === "open" || pr?.state === "draft") return `PR #${pr.number} is open`;
      if (!state.upstream) return "push the branch first";
      if (!prKnown) return ghMissing ? "gh not installed" : "still asking gh";
      return undefined;
    })();
    if (blocked || !remote || !branch) return { id: "create", label, unavailable: blocked };
    return {
      id: "create",
      label,
      description: `into ${base}`,
      run: () => openUrl(compareUrl(remote, base, branch)),
    };
  };

  const rows: MenuRow[] = [
    remote
      ? {
          id: "repo",
          label: "Open repository",
          description: remote.host,
          run: () => openUrl(repositoryUrl(remote)),
        }
      : { id: "repo", label: "Open repository", unavailable: "no supported remote" },
  ];

  if (branch) {
    rows.push({
      id: "branch",
      label: "Open branch",
      unavailable: remote ? undefined : "no supported remote",
      run: remote ? () => openUrl(branchUrl(remote, branch)) : undefined,
    });
  } else {
    const sha = state.oid || "HEAD";
    rows.push({
      id: "commit",
      label: `Open commit ${sha.slice(0, SHORT_SHA)}`,
      unavailable: remote ? undefined : "no supported remote",
      run: remote ? () => openUrl(commitUrl(remote, sha)) : undefined,
    });
  }

  if (pr) {
    rows.push({
      id: "pr",
      label: `Open pull request #${pr.number}`,
      description: pr.state,
      run: () => openUrl(pr.url),
    });
  }

  rows.push(create());
  rows.push({
    id: "copy",
    label: branch ? "Copy branch name" : "Copy commit SHA",
    run: copy(branch ?? state.oid, branch ? "branch name" : "commit SHA"),
  });
  if (pr) {
    rows.push({
      id: "copy-pr",
      label: "Copy PR URL",
      run: copy(pr.url, "pull request URL"),
    });
  }

  // The pull request is what a git click is usually after, then the branch,
  // then the repository that holds both.
  const preferred = pr ? "pr" : !remote ? "repo" : branch ? "branch" : "commit";
  const context = remote ? `${remote.owner}/${remote.repo}` : undefined;
  return { title: "Git", context, rows, preferred };
};
