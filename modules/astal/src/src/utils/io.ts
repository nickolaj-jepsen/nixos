import { GLib, Gio } from "astal";

interface WalkDirOptions {
  pattern: string;
}

export const findFiles = async (
  path: string | Gio.File,
  options?: WalkDirOptions,
): Promise<string[]> => {
  const patternSpec = options?.pattern
    ? GLib.PatternSpec.new(options.pattern)
    : null;

  // const src = Gio.File.new_for_path(path);
  const src = typeof path === "string" ? Gio.File.new_for_path(path) : path;
  const root = Gio.File.new_for_path(".");

  const iter = src.enumerate_children(
    "standard::*",
    Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
    null,
  );

  const result = [];
  while (true) {
    const [open, info, file] = iter.iterate(null);
    if (!open || !info) {
      break; // end of iterator
    }
    if (!file) {
      throw new Error("Failed to get file");
    }

    const file_type = info.get_file_type();

    if (file_type === Gio.FileType.DIRECTORY) {
      result.push(...(await findFiles(file, options)));
    }

    if (info.get_file_type() !== Gio.FileType.REGULAR) {
      continue;
    }

    const name = info.get_name();
    const path = root.get_relative_path(file);

    if (!path) {
      throw new Error("Failed to get relative path");
    }

    if (patternSpec && !patternSpec.match_string(name)) {
      continue;
    }

    result.push(`./${path}`);
  }
  return result;
};
