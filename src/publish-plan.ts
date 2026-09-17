import type {
  PublishOperation,
  PublishPlan,
  ReleaseContract,
  ReleaseManifest,
  RemoteAsset
} from "./schema.js";
import {
  parseReleaseContract,
  parseReleaseManifest,
  parsePublishPlan,
  parseRemoteAssets
} from "./schema.js";

function isMetadataRole(role: ReleaseManifest["assets"][number]["role"]): boolean {
  return role === "macos-metadata" || role === "windows-metadata";
}

function assertContractMatch(contract: ReleaseContract, manifest: ReleaseManifest): void {
  if (manifest.appId !== contract.appId) {
    throw new Error("manifestのapp-idがrelease contractと一致しません");
  }
  if (manifest.repository !== contract.repository) {
    throw new Error("manifestのrepositoryがrelease contractと一致しません");
  }
  if (manifest.tag !== contract.tag) {
    throw new Error("manifestのtagがrelease contractと一致しません");
  }
  if (manifest.version !== contract.version) {
    throw new Error("manifestのversionがrelease contractと一致しません");
  }
}

function assertUniqueRemoteNames(remoteAssets: RemoteAsset[]): Map<string, RemoteAsset> {
  const assets = new Map<string, RemoteAsset>();
  for (const remoteAsset of remoteAssets) {
    const key = remoteAsset.name;
    if (assets.has(key)) {
      throw new Error(`remote asset filenameが重複しています: ${remoteAsset.name}`);
    }
    assets.set(key, remoteAsset);
  }
  return assets;
}

function operationForAsset(
  contract: ReleaseContract,
  asset: ReleaseManifest["assets"][number],
  remoteAsset: RemoteAsset | undefined
): PublishOperation {
  if (remoteAsset === undefined) {
    return {
      action: "upload",
      name: asset.name,
      digest: asset.digest,
      size: asset.size,
      role: asset.role
    };
  }
  if (remoteAsset.digest === asset.digest) {
    return {
      action: "skip",
      name: asset.name,
      digest: asset.digest,
      size: asset.size,
      role: asset.role
    };
  }
  if (
    !contract.replaceExistingAssets ||
    contract.application.release.assetPolicy !== "replaceable"
  ) {
    throw new Error(`同名でdigestが異なるassetは置換できません: ${asset.name}`);
  }
  if (asset.role === "windows-metadata" && asset.name !== "latest.yml") {
    throw new Error("通常NSIS metadataのfilenameが不正です");
  }
  return {
    action: asset.role === "windows-metadata" ? "update-metadata" : "replace",
    name: asset.name,
    digest: asset.digest,
    size: asset.size,
    role: asset.role
  };
}

/** manifestとGitHub remote asset responseから公開計画を生成します。 */
export function createPublishPlan(
  releaseContractValue: unknown,
  manifestValue: unknown,
  remoteAssetsValue: unknown
): PublishPlan {
  const contract = parseReleaseContract(releaseContractValue);
  const manifest = parseReleaseManifest(manifestValue);
  assertContractMatch(contract, manifest);
  const remoteAssets = parseRemoteAssets(remoteAssetsValue);
  const remoteByName = assertUniqueRemoteNames(remoteAssets);
  const assets = [...manifest.assets].sort((left, right) => {
    const leftMetadata = isMetadataRole(left.role);
    const rightMetadata = isMetadataRole(right.role);
    if (leftMetadata !== rightMetadata) {
      return leftMetadata ? 1 : -1;
    }
    if (left.name < right.name) {
      return -1;
    }
    if (left.name > right.name) {
      return 1;
    }
    return 0;
  });
  const operations = assets.map((asset) =>
    operationForAsset(contract, asset, remoteByName.get(asset.name))
  );
  return parsePublishPlan({
    schemaVersion: 1,
    appId: contract.appId,
    repository: contract.repository,
    tag: contract.tag,
    operations,
    publishOrder: ["payload", "metadata"]
  });
}
