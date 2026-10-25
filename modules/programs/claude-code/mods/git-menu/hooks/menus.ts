/**
 * The menus as data, ported from pi's footer (pi/extensions/parent/chrome):
 * every git row is a link or a copy, so nothing here pushes, rebases or creates
 * anything; a row that cannot run keeps its place and says why in a few words.
 */
import type { FolderApp, Menu, Row } from "../types";

export type Forge = "github" | "gitlab" | "codeberg";

export type Remote = {
  name: string;
  forge: Forge;
  host: string;
  /** Group path, which GitLab may nest. */
  owner: string;
  repo: string;
  /** The repository's page, without a trailing slash. */
  web: string;
};

export type Status = {
  branch: string | null;
  oid: string;
  upstream: boolean;
};

export type PrKind = "open" | "draft" | "merged" | "closed";

export type Pr = { url: string; number: number; state: PrKind };

/** The branch's pull request: `null` for none, `unknown` when gh could not say. */
export type PrAnswer = Pr | null | "unknown" | "no-gh";

export const FOLDER_APPS: readonly FolderApp[] = ["code", "smerge", "files", "ghostty"];

const SHORT_SHA = 7;

// Self-hosted forges may share these layouts, but a guessed link that 404s is worse than none.
const FORGES: Record<string, Forge> = {
  "github.com": "github",
  "gitlab.com": "gitlab",
  "codeberg.org": "codeberg",
};

export const parseStatus = (output: string): Status => {
  let branch: string | null = null;
  let oid = "";
  let upstream = false;
  for (const line of output.split("\n")) {
    if (line.startsWith("# branch.head ")) {
      const head = line.slice("# branch.head ".length);
      branch = head === "(detached)" ? null : head;
    } else if (line.startsWith("# branch.oid ")) {
      oid = line.slice("# branch.oid ".length);
    } else if (line.startsWith("# branch.upstream ")) {
      upstream = true;
    }
  }
  return { branch, oid, upstream };
};

/** `gh pr view --json url,number,state,isDraft` as a Pr; undefined when it does not parse. */
export const parsePr = (stdout: string): Pr | undefined => {
  try {
    const data = JSON.parse(stdout) as {
      url: string;
      number: number;
      state: string;
      isDraft?: boolean;
    };
    const state: PrKind = data.isDraft
      ? "draft"
      : data.state === "MERGED"
        ? "merged"
        : data.state === "CLOSED"
          ? "closed"
          : "open";
    return { url: data.url, number: data.number, state };
  } catch {
    return undefined;
  }
};

/** A remote URL as a forge link, or undefined for a host this does not know. */
export const parseRemote = (name: string, raw: string): Remote | undefined => {
  const trimmed = raw
    .trim()
    .replace(/\/+$/, "")
    .replace(/\.git$/, "");
  let host: string;
  let path: string;
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed)) {
    let url: URL;
    try {
      url = new URL(trimmed);
    } catch {
      return undefined;
    }
    host = url.hostname;
    path = url.pathname;
  } else {
    // The scp-like form git writes for SSH: [user@]host:path.
    const match = /^(?:[^@/]+@)?([^:/]+):(.+)$/.exec(trimmed);
    if (!match?.[1] || !match[2]) return undefined;
    host = match[1];
    path = match[2];
  }
  host = host.toLowerCase();
  const forge = FORGES[host];
  if (!forge) return undefined;
  const segments = path.split("/").filter(Boolean);
  if (segments.length < 2) return undefined;
  const repo = segments[segments.length - 1] ?? "";
  const owner = segments.slice(0, -1).join("/");
  return { name, forge, host, owner, repo, web: `https://${host}/${owner}/${repo}` };
};

/**
 * The remote links follow: the branch's upstream remote, then `origin`, then
 * the only supported one. `config` is `git config --get-regexp '^remote\..*\.url$'`.
 */
export const chooseRemote = (config: string, branchRemote: string): Remote | undefined => {
  const remotes = new Map<string, Remote>();
  for (const line of config.split("\n")) {
    const match = /^remote\.(.+)\.url\s+(.+)$/.exec(line.trim());
    // A remote with separate fetch and push URLs lists both; the fetch URL is the page people read.
    if (!match?.[1] || !match[2] || remotes.has(match[1])) continue;
    const remote = parseRemote(match[1], match[2]);
    if (remote) remotes.set(remote.name, remote);
  }
  const supported = [...remotes.values()];
  return (
    (branchRemote && branchRemote !== "." ? remotes.get(branchRemote) : undefined) ??
    remotes.get("origin") ??
    (supported.length === 1 ? supported[0] : undefined)
  );
};

/** A branch name as URL path segments, so a `#` or a space still links. */
const segment = (text: string) => text.split("/").map(encodeURIComponent).join("/");

const branchUrl = (remote: Remote, branch: string) => {
  const leaf = segment(branch);
  switch (remote.forge) {
    case "github":
      return `${remote.web}/tree/${leaf}`;
    case "gitlab":
      return `${remote.web}/-/tree/${leaf}`;
    case "codeberg":
      return `${remote.web}/src/branch/${leaf}`;
  }
};

const commitUrl = (remote: Remote, sha: string) =>
  remote.forge === "gitlab" ? `${remote.web}/-/commit/${sha}` : `${remote.web}/commit/${sha}`;

// The compare form rather than `gh pr create --web`, which may offer to push.
const compareUrl = (remote: Remote, base: string, branch: string) =>
  `${remote.web}/compare/${segment(base)}...${segment(branch)}?expand=1`;

export type GitFacts = {
  status: Status;
  remote: Remote | undefined;
  /** The branch a new pull request targets, as `gh pr create` picks it. */
  base: string;
  pr: PrAnswer;
};

export const gitMenu = ({ status, remote, base, pr }: GitFacts): Menu => {
  const { branch } = status;
  const found = typeof pr === "object" ? pr : null;
  const noRemote = "no supported remote";
  const rows: Row[] = [
    remote
      ? {
          id: "repo",
          label: "Open repository",
          description: remote.host,
          action: { kind: "url", url: remote.web },
        }
      : { id: "repo", label: "Open repository", unavailable: noRemote },
  ];

  if (branch) {
    rows.push({
      id: "branch",
      label: "Open branch",
      unavailable: remote ? undefined : noRemote,
      action: remote ? { kind: "url", url: branchUrl(remote, branch) } : undefined,
    });
  } else {
    const sha = status.oid || "HEAD";
    rows.push({
      id: "commit",
      label: `Open commit ${sha.slice(0, SHORT_SHA)}`,
      unavailable: remote ? undefined : noRemote,
      action: remote ? { kind: "url", url: commitUrl(remote, sha) } : undefined,
    });
  }

  if (found) {
    rows.push({
      id: "pr",
      label: `Open pull request #${found.number}`,
      description: found.state,
      action: { kind: "url", url: found.url },
    });
  }

  const create =
    found && (found.state === "merged" || found.state === "closed")
      ? "Create new pull request"
      : "Create pull request";
  const blocked = !remote
    ? noRemote
    : remote.forge !== "github"
      ? "GitHub only"
      : !branch
        ? "detached HEAD"
        : found && (found.state === "open" || found.state === "draft")
          ? `PR #${found.number} is open`
          : !status.upstream
            ? "push the branch first"
            : pr === "no-gh"
              ? "gh not installed"
              : pr === "unknown"
                ? "gh could not say"
                : undefined;
  rows.push(
    blocked || !remote || !branch
      ? { id: "create", label: create, unavailable: blocked }
      : {
          id: "create",
          label: create,
          description: `into ${base}`,
          action: { kind: "url", url: compareUrl(remote, base, branch) },
        },
  );

  rows.push(
    branch
      ? {
          id: "copy",
          label: "Copy branch name",
          action: { kind: "copy", text: branch, what: "branch name" },
        }
      : {
          id: "copy",
          label: "Copy commit SHA",
          action: { kind: "copy", text: status.oid, what: "commit SHA" },
        },
  );
  if (found) {
    rows.push({
      id: "copy-pr",
      label: "Copy PR URL",
      action: { kind: "copy", text: found.url, what: "pull request URL" },
    });
  }

  // The pull request is what the menu is usually opened for, then the branch, then the repository.
  const preferred = found ? "pr" : !remote ? "repo" : branch ? "branch" : "commit";
  return {
    kind: "git",
    title: "Git",
    context: remote ? `${remote.owner}/${remote.repo}` : undefined,
    rows,
    preferred,
  };
};

export const appLabel = (app: FolderApp, isMac: boolean): string => {
  switch (app) {
    case "code":
      return "VS Code";
    case "smerge":
      return "Sublime Merge";
    case "files":
      return isMac ? "Finder" : "Files";
    case "ghostty":
      return "Ghostty";
  }
};

/**
 * The checkout in the desktop's apps, each started by its argv in `launchers`;
 * one missing keeps its row, so the order never moves.
 */
export const folderMenu = (
  cwd: string,
  launchers: Partial<Record<FolderApp, string[]>>,
  isMac: boolean,
): Menu => ({
  kind: "folder",
  title: "Open folder",
  rows: [
    ...FOLDER_APPS.map((app): Row => {
      const argv = launchers[app];
      return argv
        ? { id: app, label: appLabel(app, isMac), action: { kind: "launch", argv } }
        : { id: app, label: appLabel(app, isMac), unavailable: "not installed" };
    }),
    { id: "copy", label: "Copy path", action: { kind: "copy", text: cwd, what: "path" } },
  ],
  preferred: launchers.code ? "code" : undefined,
});
