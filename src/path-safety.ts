import { lstatSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve } from "node:path";

function isErrnoException(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error && typeof error.code === "string";
}

function pathChain(path: string): string[] {
  const chain: string[] = [];
  let current = resolve(path);
  while (true) {
    chain.push(current);
    const parent = dirname(current);
    if (parent === current) {
      break;
    }
    current = parent;
  }
  chain.reverse();
  return chain;
}

/** 既存pathの全親segmentにsymlinkがないことを検証します。 */
export function assertNoSymlinkAncestors(path: string, message: string): void {
  let current = resolve(dirname(path));
  while (true) {
    try {
      const information = lstatSync(current);
      if (information.isSymbolicLink()) {
        throw new Error(`${message}: ${current}`);
      }
      if (!information.isDirectory()) {
        throw new Error(`${message}: ${current}`);
      }
    } catch (error) {
      if (!isErrnoException(error) || error.code !== "ENOENT") {
        throw error;
      }
    }
    const parent = dirname(current);
    if (parent === current) {
      break;
    }
    current = parent;
  }
}

/** pathの全segmentが物理directoryまたはregular fileでsymlinkでないことを検証します。 */
export function assertNoSymlinkPath(path: string, message: string): void {
  for (const segment of pathChain(path)) {
    let information;
    try {
      information = lstatSync(segment);
    } catch (error) {
      throw new Error(`${message}: ${segment}`, { cause: error });
    }
    if (information.isSymbolicLink()) {
      throw new Error(`${message}: ${segment}`);
    }
  }
}

/** 実体pathがrootの内側にあることを検証します。 */
export function assertRealPathWithin(root: string, path: string, message: string): void {
  let rootRealPath: string;
  let pathRealPath: string;
  try {
    rootRealPath = realpathSync(root);
    pathRealPath = realpathSync(path);
  } catch (error) {
    throw new Error(message, { cause: error });
  }
  const relativePath = relative(rootRealPath, pathRealPath);
  if (
    isAbsolute(relativePath) ||
    relativePath === ".." ||
    relativePath.startsWith("..\\") ||
    relativePath.startsWith("../")
  ) {
    throw new Error(message);
  }
}
