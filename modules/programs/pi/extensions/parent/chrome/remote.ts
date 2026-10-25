/**
 * A checkout's remote as a web forge knows it: which host, which repository, and
 * the URL for a branch or a commit. Links follow the branch's upstream remote,
 * then `origin`, then the only remote there is, because that is where the branch
 * is published rather than where the session merely sits.
 *
 * Only GitHub, GitLab and Codeberg are recognized. A self-hosted forge may use
 * the same layouts, but guessing at a remote's web conventions produces links
 * that look right and 404, so anything else keeps its local actions and says why.
 *
 * The pull request target mirrors `gh pr create`: `branch.<name>.gh-merge-base`
 * when set, otherwise the remote's default branch.
 */
import { execFile } from "node:child_process";

export type Forge = "github" | "gitlab" | "codeberg";

export type Remote = {
  name: string;
  forge: Forge;
  host: string;
  /** Group path, which GitLab may nest, and the repository's own name. */
  owner: string;
  repo: string;
  /** The repository's page, without a trailing slash. */
  web: string;
};

export type RemoteState = {
  /** Where links point; undefined when no remote is both supported and unambiguous. */
  remote: Remote | undefined;
  /** Every supported remote, so a caller can explain an ambiguous choice. */
  supported: Remote[];
  /** The branch a new pull request would target. */
  base: string;
};

const FORGES: Record<string, Forge> = {
  "github.com": "github",
  "gitlab.com": "gitlab",
  "codeberg.org": "codeberg",
};

/** Runs one read-only git command; anything it refuses is an empty answer. */
const git = (cwd: string, args: string[]): Promise<string> =>
  new Promise((resolve) => {
    execFile(
      "git",
      ["--no-optional-locks", "-C", cwd, ...args],
      { timeout: 3000, maxBuffer: 1 << 20 },
      (error, stdout) => resolve(error ? "" : stdout.trim()),
    );
  });

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
  const forge = FORGES[host.toLowerCase()];
  if (!forge) return undefined;
  const segments = path.split("/").filter(Boolean);
  if (segments.length < 2) return undefined;
  const repo = segments[segments.length - 1] ?? "";
  const owner = segments.slice(0, -1).join("/");
  return {
    name,
    forge,
    host: host.toLowerCase(),
    owner,
    repo,
    web: `https://${host.toLowerCase()}/${owner}/${repo}`,
  };
};

/** A path segment of a branch name, encoded so a `#` or a space still links. */
const segment = (text: string) => text.split("/").map(encodeURIComponent).join("/");

export const repositoryUrl = (remote: Remote) => remote.web;

export const branchUrl = (remote: Remote, branch: string): string => {
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

export const commitUrl = (remote: Remote, sha: string): string =>
  remote.forge === "gitlab" ? `${remote.web}/-/commit/${sha}` : `${remote.web}/commit/${sha}`;

/**
 * GitHub's compare form with the pull request fields open. Built here rather
 * than through `gh pr create --web`, which may offer to push the branch: a
 * footer link states, it never changes what is on the remote.
 */
export const compareUrl = (remote: Remote, base: string, branch: string): string =>
  `${remote.web}/compare/${segment(base)}...${segment(branch)}?expand=1`;

/** Every supported remote, and the one this branch publishes to. */
export const resolveRemote = async (cwd: string, branch: string | null): Promise<RemoteState> => {
  const config = await git(cwd, ["config", "--get-regexp", "^remote\\..*\\.url$"]);
  const remotes = new Map<string, Remote>();
  for (const line of config.split("\n")) {
    const match = /^remote\.(.+)\.url\s+(.+)$/.exec(line.trim());
    if (!match?.[1] || !match[2]) continue;
    // A remote with separate fetch and push URLs lists both; the fetch URL is
    // the one whose web page people read.
    if (remotes.has(match[1])) continue;
    const remote = parseRemote(match[1], match[2]);
    if (remote) remotes.set(remote.name, remote);
  }
  const supported = [...remotes.values()];
  const branchRemote = branch ? await git(cwd, ["config", "--get", `branch.${branch}.remote`]) : "";
  const chosen =
    (branchRemote && branchRemote !== "." ? remotes.get(branchRemote) : undefined) ??
    remotes.get("origin") ??
    (supported.length === 1 ? supported[0] : undefined);

  const mergeBase = branch
    ? await git(cwd, ["config", "--get", `branch.${branch}.gh-merge-base`])
    : "";
  const base = mergeBase || (chosen ? await defaultBranch(cwd, chosen) : "main");
  return { remote: chosen, supported, base };
};

/** The remote's default branch, then the local main/master refs, then `main`. */
const defaultBranch = async (cwd: string, remote: Remote): Promise<string> => {
  const head = await git(cwd, [
    "symbolic-ref",
    "--quiet",
    "--short",
    `refs/remotes/${remote.name}/HEAD`,
  ]);
  const prefix = `${remote.name}/`;
  if (head.startsWith(prefix)) return head.slice(prefix.length);
  for (const candidate of ["main", "master"]) {
    const found = await git(cwd, [
      "rev-parse",
      "--verify",
      "--quiet",
      `refs/remotes/${remote.name}/${candidate}`,
    ]);
    if (found) return candidate;
  }
  return "main";
};
