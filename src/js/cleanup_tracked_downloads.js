#!/usr/bin/osascript -l JavaScript

ObjC.import("Foundation");

const fm = $.NSFileManager.defaultManager;

function run(argv) {
  const options = parseArgs(argv);
  if (!options.manifestPath) {
    throw new Error("Usage: cleanup_tracked_downloads.js --manifest=/path/to/manifest.json [--downloads-dir=/path] [--backup-dir=/path] [--dry-run] [--keep-fresh-downloads] [--preserve-destinations]");
  }

  const manifestPath = standardizePath(options.manifestPath);
  const downloadsDir = standardizePath(options.downloadsDir || `${homeDirectory()}/Downloads`);
  const backupDir = standardizePath(
    options.backupDir || `${directoryName(manifestPath)}/file_backups`
  );

  const manifestData = readJson(manifestPath);
  const manifest = Array.isArray(manifestData)
    ? manifestData
    : manifestData && Array.isArray(manifestData.results)
      ? manifestData.results
      : null;
  if (!Array.isArray(manifest)) {
    throw new Error(`Manifest must be a JSON array or an object with results[]: ${manifestPath}`);
  }

  const seenTargets = new Set();
  const actions = [];

  manifest.forEach((entry) => {
    const filename = validateFilename(entry && (entry.downloads_filename || entry.filename));
    const destinationPath = resolveTrackedPath(entry, downloadsDir, filename);
    const auxiliaryPaths = resolveAuxiliaryPaths(entry, downloadsDir);
    if (seenTargets.has(destinationPath)) {
      throw new Error(`Duplicate tracked path in manifest: ${destinationPath}`);
    }
    seenTargets.add(destinationPath);
    auxiliaryPaths.forEach((auxiliaryPath) => {
      if (seenTargets.has(auxiliaryPath)) {
        throw new Error(`Duplicate tracked path in manifest: ${auxiliaryPath}`);
      }
      seenTargets.add(auxiliaryPath);
    });
    const backupPath = joinPath(backupDir, filename);
    const backedUp = Boolean(entry && entry.backed_up);

    if (backedUp) {
      if (!fileExists(backupPath)) {
        actions.push({ filename, action: "missing-backup" });
        return;
      }

      if (!options.dryRun) {
        removeFileIfExists(destinationPath);
        copyFile(backupPath, destinationPath);
      }
      actions.push({ filename, action: options.dryRun ? "restore-planned" : "restored" });
      return;
    }

    if (options.preserveDestinations) {
      const existingAuxiliaryPaths = auxiliaryPaths.filter((candidatePath) =>
        fileExists(candidatePath)
      );
      if (!options.dryRun) {
        existingAuxiliaryPaths.forEach((existingPath) => {
          removeFileIfExists(existingPath);
          pruneEmptyParents(directoryName(existingPath), downloadsDir);
        });
      }
      actions.push({
        filename,
        action: fileExists(destinationPath) ? "preserved" : "already-missing",
      });
      auxiliaryPaths.forEach((auxiliaryPath) => {
        actions.push({
          filename: baseName(auxiliaryPath),
          action: existingAuxiliaryPaths.includes(auxiliaryPath)
            ? options.dryRun ? "delete-planned" : "deleted"
            : "already-missing",
        });
      });
      return;
    }

    if (options.keepFreshDownloads && isFreshDownloadEntry(entry)) {
      actions.push({ filename, action: "kept-fresh" });
      const existingAuxiliaryPaths = auxiliaryPaths.filter((candidatePath) =>
        fileExists(candidatePath)
      );
      if (!options.dryRun) {
        existingAuxiliaryPaths.forEach((existingPath) => {
          removeFileIfExists(existingPath);
          pruneEmptyParents(directoryName(existingPath), downloadsDir);
        });
      }
      auxiliaryPaths.forEach((auxiliaryPath) => {
        actions.push({
          filename: baseName(auxiliaryPath),
          action: existingAuxiliaryPaths.includes(auxiliaryPath)
            ? options.dryRun ? "delete-planned" : "deleted"
            : "already-missing",
        });
      });
      return;
    }

    const existingPaths = [destinationPath].concat(auxiliaryPaths).filter((candidatePath) =>
      fileExists(candidatePath)
    );
    if (!existingPaths.length) {
      actions.push({ filename, action: "already-missing" });
      auxiliaryPaths.forEach((auxiliaryPath) => {
        actions.push({
          filename: baseName(auxiliaryPath),
          action: "already-missing",
        });
      });
      return;
    }

    if (!options.dryRun) {
      existingPaths.forEach((existingPath) => {
        removeFileIfExists(existingPath);
        pruneEmptyParents(directoryName(existingPath), downloadsDir);
      });
    }
    actions.push({
      filename,
      action: existingPaths.includes(destinationPath)
        ? options.dryRun ? "delete-planned" : "deleted"
        : "already-missing",
    });
    auxiliaryPaths.forEach((auxiliaryPath) => {
      actions.push({
        filename: baseName(auxiliaryPath),
        action: existingPaths.includes(auxiliaryPath)
          ? options.dryRun ? "delete-planned" : "deleted"
          : "already-missing",
      });
    });
  });

  return JSON.stringify(
    {
      manifestPath,
      downloadsDir,
      backupDir,
      dryRun: options.dryRun,
      preserveDestinations: options.preserveDestinations,
      fileCount: manifest.length,
      actions,
    },
    null,
    2
  );
}

function parseArgs(argv) {
  const options = { dryRun: false, keepFreshDownloads: false, preserveDestinations: false };
  argv.forEach((arg) => {
    if (arg === "--dry-run") {
      options.dryRun = true;
      return;
    }
    if (arg === "--keep-fresh-downloads") {
      options.keepFreshDownloads = true;
      return;
    }
    if (arg === "--preserve-destinations") {
      options.preserveDestinations = true;
      return;
    }
    if (arg.startsWith("--manifest=")) {
      options.manifestPath = arg.slice("--manifest=".length);
      return;
    }
    if (arg.startsWith("--downloads-dir=")) {
      options.downloadsDir = arg.slice("--downloads-dir=".length);
      return;
    }
    if (arg.startsWith("--backup-dir=")) {
      options.backupDir = arg.slice("--backup-dir=".length);
      return;
    }
    throw new Error(`Unknown argument: ${arg}`);
  });
  return options;
}

function isFreshDownloadEntry(entry) {
  if (!entry || typeof entry !== "object") {
    return false;
  }
  if (String(entry.local_downloaded_basis || "") === "fresh-download") {
    return true;
  }
  return !(
    entry.backed_up ||
    entry.skipped_existing ||
    entry.restored_from_archive ||
    entry.reused_logged_file
  );
}

function validateFilename(filename) {
  const value = String(filename || "");
  if (!value || value === "." || value === "..") {
    throw new Error(`Invalid filename in manifest: ${value}`);
  }
  if (value.includes("/") || value.includes(":")) {
    throw new Error(`Refusing non-basename manifest entry: ${value}`);
  }
  return value;
}

function validateRelativePath(relativePath) {
  const value = String(relativePath || "").trim();
  if (!value) {
    throw new Error(`Invalid relative path in manifest: ${value}`);
  }
  if (value.startsWith("/") || value.includes("\\") || value.split("/").includes("..")) {
    throw new Error(`Refusing unsafe relative path in manifest: ${value}`);
  }
  return value;
}

function resolveTrackedPath(entry, downloadsDir, fallbackFilename) {
  const explicitPath = entry && entry.downloads_path ? standardizePath(entry.downloads_path) : "";
  if (explicitPath) {
    ensureWithinRoot(explicitPath, downloadsDir);
    return explicitPath;
  }
  const relativePath = entry && entry.downloads_relative_path
    ? validateRelativePath(entry.downloads_relative_path)
    : "";
  if (relativePath) {
    return joinPath(downloadsDir, relativePath);
  }
  return joinPath(downloadsDir, fallbackFilename);
}

function resolveAuxiliaryPaths(entry, downloadsDir) {
  const values =
    entry && Array.isArray(entry.auxiliary_paths) ? entry.auxiliary_paths : [];
  return values.map((path) => {
    const normalizedPath = standardizePath(path);
    ensureWithinRoot(normalizedPath, downloadsDir);
    return normalizedPath;
  });
}

function ensureWithinRoot(path, root) {
  const normalizedPath = standardizePath(path);
  const normalizedRoot = standardizePath(root);
  if (normalizedPath === normalizedRoot || normalizedPath.startsWith(`${normalizedRoot}/`)) {
    return;
  }
  throw new Error(`Refusing path outside downloads root: ${normalizedPath}`);
}

function readJson(path) {
  const data = $.NSData.dataWithContentsOfFile(path);
  if (!data) {
    throw new Error(`Failed to read ${path}`);
  }
  const error = Ref();
  const obj = $.NSJSONSerialization.JSONObjectWithDataOptionsError(data, 0, error);
  if (!obj) {
    throw new Error(`Failed to parse JSON ${path}: ${unwrapError(error)}`);
  }
  return ObjC.deepUnwrap(obj);
}

function fileExists(path) {
  return fm.fileExistsAtPath(path);
}

function removeFileIfExists(path) {
  if (!fileExists(path)) {
    return;
  }
  const error = Ref();
  const ok = fm.removeItemAtPathError(path, error);
  if (!ok) {
    throw new Error(`Failed to remove ${path}: ${unwrapError(error)}`);
  }
}

function pruneEmptyParents(path, stopAt) {
  let current = standardizePath(path);
  const stopRoot = standardizePath(stopAt);
  while (current && current !== stopRoot) {
    if (!fileExists(current) || !directoryIsEmpty(current)) {
      return;
    }
    const error = Ref();
    const ok = fm.removeItemAtPathError(current, error);
    if (!ok) {
      throw new Error(`Failed to remove empty directory ${current}: ${unwrapError(error)}`);
    }
    current = directoryName(current);
  }
}

function directoryIsEmpty(path) {
  const error = Ref();
  const items = fm.contentsOfDirectoryAtPathError(path, error);
  if (!items) {
    throw new Error(`Failed to read directory ${path}: ${unwrapError(error)}`);
  }
  return ObjC.deepUnwrap(items).length === 0;
}

function copyFile(src, dest) {
  const error = Ref();
  const ok = fm.copyItemAtPathToPathError(src, dest, error);
  if (!ok) {
    throw new Error(`Failed to copy ${src} -> ${dest}: ${unwrapError(error)}`);
  }
}

function standardizePath(path) {
  return ObjC.unwrap($(String(path)).stringByStandardizingPath);
}

function directoryName(path) {
  return ObjC.unwrap($(path).stringByDeletingLastPathComponent);
}

function baseName(path) {
  return ObjC.unwrap($(path).lastPathComponent);
}

function joinPath(base, child) {
  return ObjC.unwrap($(base).stringByAppendingPathComponent($(child)));
}

function homeDirectory() {
  return ObjC.unwrap($.NSHomeDirectory());
}

function unwrapError(errorRef) {
  if (!errorRef || !errorRef[0]) {
    return "unknown error";
  }
  return ObjC.unwrap(errorRef[0].localizedDescription);
}
