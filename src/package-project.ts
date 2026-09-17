import { existsSync, lstatSync, mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { stringify as stringifyYaml } from "yaml";
import type { ReleaseContract } from "./schema.js";
import { parseReleaseContract } from "./schema.js";

function assertEmptyDirectory(path: string): void {
  if (!existsSync(path)) {
    mkdirSync(path, { recursive: true });
    return;
  }
  const information = lstatSync(path);
  if (!information.isDirectory()) {
    throw new Error(`output-directoryがディレクトリではありません: ${path}`);
  }
  if (readdirSync(path).length > 0) {
    throw new Error(`output-directoryは空でなければなりません: ${path}`);
  }
}

function packageJson(contract: ReleaseContract): Record<string, unknown> {
  return {
    name: contract.application.packageName,
    version: contract.version,
    private: true,
    repository: {
      type: "git",
      url: `https://github.com/${contract.repository}.git`
    }
  };
}

function builderConfig(
  contract: ReleaseContract,
  platform: "macos" | "windows"
): Record<string, unknown> {
  const repositoryParts = contract.repository.split("/");
  if (repositoryParts.length !== 2) {
    throw new Error("repositoryはowner/name形式でなければなりません");
  }
  const owner = repositoryParts[0];
  const repo = repositoryParts[1];
  if (owner === undefined || repo === undefined) {
    throw new Error("repositoryのownerまたはnameがありません");
  }
  const common: Record<string, unknown> = {
    appId: contract.application.identity.appId,
    productName: contract.application.identity.productName,
    publish: {
      provider: "github",
      owner,
      repo,
      channel: contract.application.release.channel
    }
  };
  if (platform === "macos") {
    return {
      ...common,
      mac: {
        target: [
          {
            target: "zip",
            arch: [contract.application.macos.architecture]
          },
          {
            target: "dmg",
            arch: [contract.application.macos.architecture]
          }
        ],
        artifactName: "${productName}-${version}-${arch}.${ext}",
        entitlements: contract.application.macos.entitlements,
        entitlementsInherit: contract.application.macos.entitlementsInherit,
        hardenedRuntime: true,
        gatekeeperAssess: false
      }
    };
  }
  return {
    ...common,
    win: {
      target: [
        {
          target: "nsis",
          arch: [contract.application.windows.architecture]
        },
        {
          target: "nsis-web",
          arch: [contract.application.windows.architecture]
        }
      ],
      executableName: contract.application.windows.executableName,
      publisherName: contract.application.windows.publisherName
    },
    nsis: {
      guid: contract.application.windows.guid,
      artifactName: "${productName} Setup ${version}.${ext}"
    },
    nsisWeb: {
      artifactName: "${productName} Web Setup ${version}.${ext}"
    }
  };
}

/** prepackaged用の最小package projectを生成します。 */
export function createPackageProject(
  releaseContractValue: unknown,
  platform: "macos" | "windows",
  outputDirectory: string
): void {
  const releaseContract = parseReleaseContract(releaseContractValue);
  assertEmptyDirectory(outputDirectory);
  const packageContents = JSON.stringify(packageJson(releaseContract), null, 2);
  if (packageContents === undefined) {
    throw new Error("package.jsonを生成できません");
  }
  const builderContents = stringifyYaml(builderConfig(releaseContract, platform));
  writeFileSync(join(outputDirectory, "package.json"), `${packageContents}\n`, "utf8");
  writeFileSync(join(outputDirectory, "electron-builder.yml"), builderContents, "utf8");
}
