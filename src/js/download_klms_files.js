#!/usr/bin/osascript -l JavaScript

ObjC.import("Foundation");
const currentApp = Application.currentApplication();

function run(argv) {
  const options = parseArgs(argv);
  if (!options.manifestPath || !options.outputRoot) {
    throw new Error(
      "Usage: download_klms_files.js --manifest=/path/to/manifest.json --output-root=/path [--base-url=https://klms.kaist.ac.kr/my/] [--downloads-dir=/path] [--timeout=60] [--max-file-attempts=3] [--retry-delay-seconds=2] [--download-log=/path/to/log.json] [--download-archive-root=/path] [--force-download]"
    );
  }

  const manifestPath = standardizePath(options.manifestPath);
  const outputRoot = standardizePath(options.outputRoot);
  const baseUrl = options.baseUrl || "https://klms.kaist.ac.kr/my/";
  const downloadsDir = standardizePath(options.downloadsDir || `${homeDirectory()}/Downloads`);
  const timeoutSeconds = Math.max(5, Number(options.timeoutSeconds || "60"));
  const maxFileAttempts = Math.max(1, Number(options.maxFileAttempts || "3"));
  const retryDelaySeconds = Math.max(0, Number(options.retryDelaySeconds || "2"));
  const backupRoot = standardizePath(options.backupRoot || `${outputRoot}/../runtime/tmp/download_backups`);
  const downloadArchiveRoot = standardizePath(
    options.downloadArchiveRoot || joinPath(downloadsDir, "KLMS Files")
  );
  const downloadLogPath = standardizePath(
    options.downloadLogPath || joinPath(directoryName(outputRoot), "runtime/cache/course_file_download_log.json")
  );
  const manifestStatePath = standardizePath(
    options.manifestStatePath || joinPath(directoryName(manifestPath), "course_file_manifest_state.json")
  );
  const projectRoot = findProjectRoot(manifestPath, outputRoot);
  const forceDownload = normalizeBoolean(options.forceDownload);
  const manifest = readJson(manifestPath);
  const manifestState = readOptionalJson(manifestStatePath);
  const previousDownloadLog = readOptionalJson(downloadLogPath);
  const reusableFileIndex = buildReusableFileIndex(previousDownloadLog);
  const recordedFilenameIndex = buildRecordedFilenameIndex(previousDownloadLog);
  const localDownloadMetadataIndex = buildLocalDownloadMetadataIndex(previousDownloadLog);
  if (!Array.isArray(manifest)) {
    throw new Error(`Manifest must be a JSON array: ${manifestPath}`);
  }

  let safari = null;
  let downloadWindowRef = null;

  let topLevelStep = "ensure-output-root";
  const results = [];
  const claimedAuxiliaryPaths = new Set();
  const claimedRelativePaths = new Set();

  try {
    ensureDir(outputRoot);
    ensureDir(backupRoot);
    ensureDir(downloadArchiveRoot);
    ensureDir(directoryName(downloadLogPath));
    topLevelStep = "download-loop";
    for (let index = 0; index < manifest.length; index += 1) {
      const entry = manifest[index];
      topLevelStep = `file-${index + 1}`;
      let completed = false;
      let lastError = null;

      for (let attempt = 1; attempt <= maxFileAttempts; attempt += 1) {
        let step = "relative-path";
        let fileWindowRef = null;
        let backupPath = "";
        let backupOriginalPath = "";
        let preservedDownloadPath = "";
        let auxiliaryPaths = [];

        try {
        const manifestRelativePath = String(entry.relative_path || entry.filename || "").trim();
        const relativeDir = directoryName(manifestRelativePath);
        const manifestFilename = String(entry.filename || baseName(manifestRelativePath) || "").trim();
        const buildRelativePath = (filename) => (relativeDir ? joinPath(relativeDir, filename) : filename);
        const buildDestinationPath = (filename) => joinPath(outputRoot, buildRelativePath(filename));
        const buildArchivePath = (filename) => joinPath(downloadArchiveRoot, buildRelativePath(filename));
        const destinationDir = relativeDir ? joinPath(outputRoot, relativeDir) : outputRoot;
        const archiveDir = relativeDir ? joinPath(downloadArchiveRoot, relativeDir) : downloadArchiveRoot;
        let activeFilename = recordedFilenameForEntry(entry, recordedFilenameIndex) || manifestFilename;

        step = "join-path";
        let relativePath = activeFilename ? buildRelativePath(activeFilename) : manifestRelativePath;
        let destinationPath = activeFilename ? buildDestinationPath(activeFilename) : "";
        let trackedArchivePath = activeFilename ? buildArchivePath(activeFilename) : "";
        step = "ensure-dir";
        ensureDir(destinationDir);
        ensureDir(archiveDir);

        step = "cleanup-artifacts";
        removeDirectoryArtifactIfExists(destinationPath);
        removeDirectoryArtifactIfExists(trackedArchivePath);

        if (!forceDownload && destinationPath && isRegularFile(destinationPath)) {
          const existingSourcePath = destinationPath;
          step = "claim-existing-path";
          let trackedPaths = claimTrackedPath(
            activeFilename,
            manifestRelativePath,
            relativeDir,
            outputRoot,
            downloadArchiveRoot,
            claimedRelativePaths
          );
          activeFilename = trackedPaths.activeFilename;
          relativePath = trackedPaths.relativePath;
          destinationPath = trackedPaths.destinationPath;
          trackedArchivePath = trackedPaths.trackedArchivePath;
          ensureDir(directoryName(destinationPath));
          ensureDir(directoryName(trackedArchivePath));
          if (!samePath(existingSourcePath, destinationPath) && !isRegularFile(destinationPath)) {
            copyFile(existingSourcePath, destinationPath);
          }
          if (trackedArchivePath && !isRegularFile(trackedArchivePath)) {
            step = "mirror-existing-to-archive";
            copyFile(destinationPath, trackedArchivePath);
          }
          step = "apply-klms-timestamp";
          applyKlmsTimestampToPaths([destinationPath, trackedArchivePath], entry);
          updateManifestEntryWithFilename(entry, activeFilename, relativePath, destinationPath);
          const localDownloadMetadata = resolveLocalDownloadMetadata(
            entry,
            localDownloadMetadataIndex,
            destinationPath || trackedArchivePath,
            "existing-file"
          );
          applyLocalDownloadMetadata(entry, localDownloadMetadata);
          const resultAuxiliaryPaths = claimAuxiliaryPaths(
            buildLegacyDownloadAuxiliaryPaths(
              downloadsDir,
              trackedArchivePath,
              activeFilename,
              fileSize(destinationPath)
            ),
            claimedAuxiliaryPaths
          );
          step = "record-existing-result";
          const result = {
            index: index + 1,
            course: entry.course || "",
            filename: activeFilename,
            relative_path: relativePath,
            manifest_filename: manifestFilename,
            manifest_relative_path: manifestRelativePath,
            destination_path: destinationPath,
            downloads_root: downloadArchiveRoot,
            downloads_relative_path: relativePath,
            downloads_filename: trackedArchivePath ? baseName(trackedArchivePath) : "",
            downloads_path: trackedArchivePath,
            bytes: fileSize(destinationPath),
            source_url: entry.source_url || "",
            url: entry.url || "",
            skipped_existing: true,
            auxiliary_paths: resultAuxiliaryPaths,
          };
          addKlmsTimestampFields(result, entry);
          addLocalDownloadMetadataFields(result, localDownloadMetadata);
          results.push(result);
          persistDownloadProgress(
            manifestPath,
            manifest,
            manifestStatePath,
            manifestState,
            downloadLogPath,
            outputRoot,
            results
          );
          completed = true;
          break;
        }

        if (!forceDownload && trackedArchivePath && isRegularFile(trackedArchivePath)) {
          const archiveSourcePath = trackedArchivePath;
          step = "claim-archive-path";
          let trackedPaths = claimTrackedPath(
            activeFilename,
            manifestRelativePath,
            relativeDir,
            outputRoot,
            downloadArchiveRoot,
            claimedRelativePaths
          );
          activeFilename = trackedPaths.activeFilename;
          relativePath = trackedPaths.relativePath;
          destinationPath = trackedPaths.destinationPath;
          trackedArchivePath = trackedPaths.trackedArchivePath;
          ensureDir(directoryName(destinationPath));
          ensureDir(directoryName(trackedArchivePath));
          step = "restore-from-archive";
          copyFile(archiveSourcePath, destinationPath);
          if (!samePath(archiveSourcePath, trackedArchivePath) && !isRegularFile(trackedArchivePath)) {
            copyFile(archiveSourcePath, trackedArchivePath);
          }
          step = "apply-klms-timestamp";
          applyKlmsTimestampToPaths([destinationPath, trackedArchivePath], entry);
          updateManifestEntryWithFilename(entry, activeFilename, relativePath, destinationPath);
          const localDownloadMetadata = resolveLocalDownloadMetadata(
            entry,
            localDownloadMetadataIndex,
            trackedArchivePath || destinationPath,
            "restored-from-archive"
          );
          applyLocalDownloadMetadata(entry, localDownloadMetadata);
          const resultAuxiliaryPaths = claimAuxiliaryPaths(
            buildLegacyDownloadAuxiliaryPaths(
              downloadsDir,
              trackedArchivePath,
              activeFilename,
              fileSize(destinationPath)
            ),
            claimedAuxiliaryPaths
          );
          const result = {
            index: index + 1,
            course: entry.course || "",
            filename: activeFilename,
            relative_path: relativePath,
            manifest_filename: manifestFilename,
            manifest_relative_path: manifestRelativePath,
            destination_path: destinationPath,
            downloads_root: downloadArchiveRoot,
            downloads_relative_path: relativePath,
            downloads_filename: baseName(trackedArchivePath),
            downloads_path: trackedArchivePath,
            bytes: fileSize(destinationPath),
            source_url: entry.source_url || "",
            url: entry.url || "",
            restored_from_archive: true,
            auxiliary_paths: resultAuxiliaryPaths,
          };
          addKlmsTimestampFields(result, entry);
          addLocalDownloadMetadataFields(result, localDownloadMetadata);
          results.push(result);
          persistDownloadProgress(
            manifestPath,
            manifest,
            manifestStatePath,
            manifestState,
            downloadLogPath,
            outputRoot,
            results
          );
          completed = true;
          break;
        }

        const reusableSourcePath = forceDownload
          ? ""
          : findReusableSourcePath(reusableFileIndex, entry, destinationPath, trackedArchivePath);
        if (reusableSourcePath) {
          step = "reuse-previous-download";
          activeFilename = baseName(reusableSourcePath) || manifestFilename;
          if (!activeFilename) {
            throw new Error(`Missing reusable filename for ${entry.url || manifestRelativePath}`);
          }
          let trackedPaths = claimTrackedPath(
            activeFilename,
            manifestRelativePath,
            relativeDir,
            outputRoot,
            downloadArchiveRoot,
            claimedRelativePaths
          );
          activeFilename = trackedPaths.activeFilename;
          relativePath = trackedPaths.relativePath;
          destinationPath = trackedPaths.destinationPath;
          trackedArchivePath = trackedPaths.trackedArchivePath;

          removeDirectoryArtifactIfExists(destinationPath);
          removeDirectoryArtifactIfExists(trackedArchivePath);
          if (!isRegularFile(destinationPath)) {
            copyFile(reusableSourcePath, destinationPath);
          }
          if (!isRegularFile(trackedArchivePath)) {
            copyFile(reusableSourcePath, trackedArchivePath);
          }
          step = "apply-klms-timestamp";
          applyKlmsTimestampToPaths([destinationPath, trackedArchivePath], entry);
          updateManifestEntryWithFilename(entry, activeFilename, relativePath, destinationPath);
          const localDownloadMetadata = resolveLocalDownloadMetadata(
            entry,
            localDownloadMetadataIndex,
            reusableSourcePath || destinationPath || trackedArchivePath,
            "reused-logged-file"
          );
          applyLocalDownloadMetadata(entry, localDownloadMetadata);
          const resultAuxiliaryPaths = claimAuxiliaryPaths(
            buildLegacyDownloadAuxiliaryPaths(
              downloadsDir,
              trackedArchivePath,
              activeFilename,
              fileSize(destinationPath)
            ),
            claimedAuxiliaryPaths
          );
          const result = {
            index: index + 1,
            course: entry.course || "",
            filename: activeFilename,
            relative_path: relativePath,
            manifest_filename: manifestFilename,
            manifest_relative_path: manifestRelativePath,
            destination_path: destinationPath,
            downloads_root: downloadArchiveRoot,
            downloads_relative_path: relativePath,
            downloads_filename: baseName(trackedArchivePath),
            downloads_path: trackedArchivePath,
            bytes: fileSize(destinationPath),
            source_url: entry.source_url || "",
            url: entry.url || "",
            reused_logged_file: true,
            reused_from_path: reusableSourcePath,
            auxiliary_paths: resultAuxiliaryPaths,
          };
          addKlmsTimestampFields(result, entry);
          addLocalDownloadMetadataFields(result, localDownloadMetadata);
          results.push(result);
          persistDownloadProgress(
            manifestPath,
            manifest,
            manifestStatePath,
            manifestState,
            downloadLogPath,
            outputRoot,
            results
          );
          completed = true;
          break;
        }

        step = "list-downloads-before";
        const existingDownloadPath = manifestFilename ? joinPath(downloadsDir, manifestFilename) : "";
        removeDirectoryArtifactIfExists(existingDownloadPath);
        if (manifestFilename && isRegularFile(existingDownloadPath)) {
          backupOriginalPath = existingDownloadPath;
          backupPath = joinPath(
            backupRoot,
            `${String(index + 1).padStart(3, "0")}-${manifestFilename}`
          );
          moveFile(existingDownloadPath, backupPath);
        }

        const beforeEntries = new Set(listDirectory(downloadsDir));
        const beforeEntrySignatures = buildDirectoryEntrySignatures(downloadsDir, beforeEntries);
        const originalUrl = String(entry.url || "");
        const targetUrl = withForcedDownload(originalUrl);
        const isResourceViewDownload = String(entry.url || "").includes("/mod/resource/view.php?");
        const isMediaPluginDownload =
          /klms\.kaist\.ac\.kr\/pluginfile\.php\/.+\.(mp4|m4v|mov|mp3|m4a|wav)(?:[?#].*)?$/i.test(
            String(entry.url || "")
          );
        const allowAnyDownload = isResourceViewDownload || isMediaPluginDownload;
        const perFileTimeoutSeconds = isMediaPluginDownload
          ? Math.max(timeoutSeconds, 600)
          : timeoutSeconds;
        if (!targetUrl) {
          throw new Error(`Missing URL for ${manifestRelativePath}`);
        }

        step = "launch-safari";
        safari = ensureSafari(safari);
        let downloadedPath = "";
        const directFetchPage = String(entry.source_url || baseUrl || "").trim() || targetUrl;
        step = "open-download-page";
        downloadWindowRef = openReusableDownloadPage(
          safari,
          downloadWindowRef,
          canDirectFetchKlmsFile(targetUrl) ? directFetchPage : targetUrl
        );
        fileWindowRef = downloadWindowRef;

        if (canDirectFetchKlmsFile(targetUrl)) {
          step = "direct-fetch";
          downloadedPath = fetchKlmsFileViaSafari(
            fileWindowRef,
            targetUrl,
            backupRoot,
            index + 1,
            manifestFilename || `attachment-${index + 1}`
          );
          if (!downloadedPath) {
            const tab = safeValue(() => fileWindowRef.currentTab());
            if (tab) {
              navigateTabWithoutFocus(tab, targetUrl);
              delay(0.5);
            }
          }
        }

        const redirectedDirectUrl = resolveDirectFileUrlFromWindow(fileWindowRef);
        if (!downloadedPath && canDirectFetchKlmsFile(redirectedDirectUrl)) {
          step = "direct-fetch-redirected";
          downloadedPath = fetchKlmsFileViaSafari(
            fileWindowRef,
            redirectedDirectUrl,
            backupRoot,
            index + 1,
            manifestFilename || `attachment-${index + 1}`
          );
        }

        const viewerUrlHint = extractSynapViewerUrl(fileWindowRef);

        if (!downloadedPath && viewerUrlHint && /\.pdf$/i.test(manifestFilename || "")) {
          step = "recover-synap-viewer-pdf";
          downloadedPath = recoverSynapViewerPdf(
            fileWindowRef,
            manifestFilename,
            backupRoot,
            projectRoot,
            index + 1,
            perFileTimeoutSeconds,
            viewerUrlHint
          );
        }

        if (
          !downloadedPath &&
          (allowAnyDownload || canDirectFetchKlmsFile(currentTabUrl(fileWindowRef)))
        ) {
          step = "retry-inline-resource-download-early";
          downloadedPath = retryInlineResourceDownload(
            fileWindowRef,
            downloadsDir,
            beforeEntries,
            beforeEntrySignatures,
            manifestFilename,
            Math.min(perFileTimeoutSeconds, 30)
          );
        }

        if (!downloadedPath && /\.zip$/i.test(manifestFilename || "")) {
          step = "recover-auto-unzipped-archive-early";
          const recovered = waitForAutoUnzippedArchive(
            downloadsDir,
            beforeEntries,
            manifestFilename,
            Math.min(perFileTimeoutSeconds, 20)
          );
          downloadedPath = recovered.path;
          auxiliaryPaths = recovered.auxiliaryPaths;
        }

        if (!downloadedPath) {
          step = "wait-download";
          downloadedPath = waitForDownloadedFile(
            downloadsDir,
            beforeEntries,
            beforeEntrySignatures,
            manifestFilename,
            perFileTimeoutSeconds,
            allowAnyDownload
          );
        }

        if (
          !downloadedPath &&
          (allowAnyDownload || canDirectFetchKlmsFile(currentTabUrl(fileWindowRef)))
        ) {
          step = "retry-inline-resource-download";
          downloadedPath = retryInlineResourceDownload(
            fileWindowRef,
            downloadsDir,
            beforeEntries,
            beforeEntrySignatures,
            manifestFilename,
            perFileTimeoutSeconds
          );
        }

        if (!downloadedPath) {
          step = "recover-auto-unzipped-archive";
          const recovered = recoverAutoUnzippedArchive(
            downloadsDir,
            beforeEntries,
            manifestFilename
          );
          downloadedPath = recovered.path;
          auxiliaryPaths = recovered.auxiliaryPaths;
        }

        if (!downloadedPath) {
          step = "recover-synap-viewer-pdf";
          const recoveredPdfPath = recoverSynapViewerPdf(
            fileWindowRef,
            manifestFilename,
            backupRoot,
            projectRoot,
            index + 1,
            perFileTimeoutSeconds
          );
          if (recoveredPdfPath) {
            downloadedPath = recoveredPdfPath;
          }
        }

        if (!downloadedPath) {
          const activeUrl = currentTabUrl(fileWindowRef);
          if (activeUrl.includes("/login/")) {
            throw new Error(`Login required while downloading: ${entry.url}`);
          }
          throw new Error(`Timed out waiting for download: ${entry.url}`);
        }

        activeFilename = baseName(downloadedPath) || manifestFilename;
        if (!activeFilename) {
          throw new Error(`Could not determine downloaded filename: ${downloadedPath}`);
        }
        if (!filenameCompatibleWithExpected(activeFilename, manifestFilename)) {
          throw new Error(
            `Downloaded filename does not match expected file type: ${activeFilename} expected ${manifestFilename}`
          );
        }
        if (isIgnoredDownloadName(activeFilename)) {
          throw new Error(`Ignoring hidden/system download artifact: ${downloadedPath}`);
        }
        if (isTransientDownloadName(activeFilename)) {
          if (!manifestFilename) {
            throw new Error(`Refusing transient download filename without manifest fallback: ${downloadedPath}`);
          }
          activeFilename = manifestFilename;
        }
        let trackedPaths = claimTrackedPath(
          activeFilename,
          manifestRelativePath,
          relativeDir,
          outputRoot,
          downloadArchiveRoot,
          claimedRelativePaths
        );
        activeFilename = trackedPaths.activeFilename;
        relativePath = trackedPaths.relativePath;
        destinationPath = trackedPaths.destinationPath;
        trackedArchivePath = trackedPaths.trackedArchivePath;

        step = "copy-file";
        copyFile(downloadedPath, destinationPath);
        step = "preserve-download";
        preservedDownloadPath = preserveDownloadedCopy(downloadedPath, trackedArchivePath);
        step = "apply-klms-timestamp";
        applyKlmsTimestampToPaths([destinationPath, preservedDownloadPath], entry);
        updateManifestEntryWithFilename(entry, activeFilename, relativePath, destinationPath);
        const localDownloadMetadata = currentLocalDownloadMetadata("fresh-download");
        applyLocalDownloadMetadata(entry, localDownloadMetadata);
        step = "record-result";
        const result = {
          index: index + 1,
          course: entry.course || "",
          filename: activeFilename,
          relative_path: relativePath,
          manifest_filename: manifestFilename,
          manifest_relative_path: manifestRelativePath,
          destination_path: destinationPath,
          downloads_root: downloadArchiveRoot,
          downloads_relative_path: relativePath,
          downloads_filename: baseName(preservedDownloadPath),
          downloads_path: preservedDownloadPath,
          bytes: fileSize(destinationPath),
          source_url: entry.source_url || "",
          url: entry.url || "",
          auxiliary_paths: claimAuxiliaryPaths(auxiliaryPaths, claimedAuxiliaryPaths),
          forced_download: forceDownload,
        };
        addKlmsTimestampFields(result, entry);
        addLocalDownloadMetadataFields(result, localDownloadMetadata);
        results.push(result);
        persistDownloadProgress(
          manifestPath,
          manifest,
          manifestStatePath,
          manifestState,
          downloadLogPath,
          outputRoot,
          results
        );
        completed = true;
      } catch (error) {
        lastError = new Error(
          `File ${index + 1} failed at ${step} (attempt ${attempt}/${maxFileAttempts}): ${error}`
        );
        if (
          attempt < maxFileAttempts &&
          shouldRetryDownloadError(String(error || ""))
        ) {
          safari = resetSafariForRetry(safari);
          downloadWindowRef = null;
          if (retryDelaySeconds > 0) {
            delay(retryDelaySeconds);
          }
        } else {
          throw lastError;
        }
      } finally {
        if (
          backupPath &&
          backupOriginalPath &&
          fileExists(backupPath) &&
          !fileExists(backupOriginalPath)
        ) {
          try {
            moveFile(backupPath, backupOriginalPath);
          } catch (_error) {
            // Ignore backup restore failures and preserve progress.
          }
        }
      }

        if (completed) {
          break;
        }
      }

      if (!completed && lastError) {
        throw lastError;
      }
    }
  } catch (error) {
    throw new Error(`Download failed at ${topLevelStep}: ${error}`);
  }

  persistDownloadProgress(
    manifestPath,
    manifest,
    manifestStatePath,
    manifestState,
    downloadLogPath,
    outputRoot,
    results
  );

	  const payload = buildDownloadPayload(manifestPath, outputRoot, downloadLogPath, results);
	  if (options.resultJsonPath) {
	    const resultJsonPath = standardizePath(options.resultJsonPath);
	    ensureDir(directoryName(resultJsonPath));
	    writeJson(resultJsonPath, payload);
	    return JSON.stringify({
	      resultPath: resultJsonPath,
	      fileCount: payload.fileCount,
	    });
	  }
	  return JSON.stringify(payload, null, 2);
	}

function parseArgs(argv) {
  const options = {};
  argv.forEach((arg) => {
    if (arg === "--force-download") {
      options.forceDownload = "1";
      return;
    }
    if (arg.startsWith("--manifest=")) {
      options.manifestPath = arg.slice("--manifest=".length);
      return;
    }
    if (arg.startsWith("--output-root=")) {
      options.outputRoot = arg.slice("--output-root=".length);
      return;
    }
    if (arg.startsWith("--base-url=")) {
      options.baseUrl = arg.slice("--base-url=".length);
      return;
    }
    if (arg.startsWith("--downloads-dir=")) {
      options.downloadsDir = arg.slice("--downloads-dir=".length);
      return;
    }
    if (arg.startsWith("--timeout=")) {
      options.timeoutSeconds = arg.slice("--timeout=".length);
      return;
    }
    if (arg.startsWith("--max-file-attempts=")) {
      options.maxFileAttempts = arg.slice("--max-file-attempts=".length);
      return;
    }
    if (arg.startsWith("--retry-delay-seconds=")) {
      options.retryDelaySeconds = arg.slice("--retry-delay-seconds=".length);
      return;
    }
    if (arg.startsWith("--backup-root=")) {
      options.backupRoot = arg.slice("--backup-root=".length);
      return;
    }
	    if (arg.startsWith("--download-log=")) {
	      options.downloadLogPath = arg.slice("--download-log=".length);
	      return;
	    }
	    if (arg.startsWith("--result-json=")) {
	      options.resultJsonPath = arg.slice("--result-json=".length);
	      return;
	    }
    if (arg.startsWith("--manifest-state-json=")) {
      options.manifestStatePath = arg.slice("--manifest-state-json=".length);
      return;
    }
    if (arg.startsWith("--download-archive-root=")) {
      options.downloadArchiveRoot = arg.slice("--download-archive-root=".length);
      return;
    }
    if (arg.startsWith("--force-download=")) {
      options.forceDownload = arg.slice("--force-download=".length);
      return;
    }
    throw new Error(`Unknown argument: ${arg}`);
  });
  return options;
}

function buildDownloadPayload(manifestPath, outputRoot, downloadLogPath, results) {
  return {
    manifestPath,
    outputRoot,
    downloadLogPath,
    fileCount: results.length,
    results,
  };
}

function persistDownloadProgress(
  manifestPath,
  manifest,
  manifestStatePath,
  manifestState,
  downloadLogPath,
  outputRoot,
  results
) {
  writeJson(manifestPath, manifest);
  if (manifestState && typeof manifestState === "object" && manifestState.sources) {
    writeJson(manifestStatePath, manifestState);
  }
  writeJson(downloadLogPath, buildDownloadPayload(manifestPath, outputRoot, downloadLogPath, results));
}

function normalizeBoolean(value) {
  if (value == null) {
    return false;
  }
  const text = String(value).trim().toLowerCase();
  if (!text) {
    return false;
  }
  return !["0", "false", "no", "off"].includes(text);
}

function shouldRetryDownloadError(message) {
  const text = String(message || "").toLowerCase();
  if (!text) {
    return false;
  }
  if (text.includes("login required")) {
    return false;
  }
  return [
    "timed out waiting for download",
    "ignoring hidden/system download artifact",
    "connection invalid",
    "메시지를 이해할 수 없습니다",
    "could not create transient safari window",
    "empty-result",
    "http-",
  ].some((pattern) => text.includes(pattern));
}

function resetSafariForRetry(_existingSafari) {
  return null;
}

function updateManifestEntryWithFilename(entry, filename, relativePath, destinationPath) {
  entry.filename = String(filename || "");
  entry.relative_path = String(relativePath || "");
  entry.absolute_path = String(destinationPath || "");
}

function claimTrackedPath(
  filename,
  fallbackRelativePath,
  relativeDir,
  outputRoot,
  downloadArchiveRoot,
  claimedRelativePaths
) {
  const candidateFilename = String(filename || "").trim();
  const fallback = String(fallbackRelativePath || "").trim();
  let preferredRelativePath = candidateFilename
    ? relativeDir ? joinPath(relativeDir, candidateFilename) : candidateFilename
    : fallback;

  if (
    preferredRelativePath &&
    claimedRelativePaths.has(preferredRelativePath) &&
    fallback &&
    !claimedRelativePaths.has(fallback)
  ) {
    preferredRelativePath = fallback;
  }

  const relativePath = claimUniqueRelativePath(preferredRelativePath, claimedRelativePaths);
  const activeFilename = baseName(relativePath) || candidateFilename || baseName(fallback);
  return {
    activeFilename,
    relativePath,
    destinationPath: relativePath ? joinPath(outputRoot, relativePath) : "",
    trackedArchivePath: relativePath ? joinPath(downloadArchiveRoot, relativePath) : "",
  };
}

function claimUniqueRelativePath(relativePath, claimedRelativePaths) {
  const preferred = String(relativePath || "").trim();
  if (!preferred) {
    return "";
  }
  if (!claimedRelativePaths.has(preferred)) {
    claimedRelativePaths.add(preferred);
    return preferred;
  }

  const dir = directoryName(preferred);
  const name = baseName(preferred);
  const split = splitFileName(name);
  for (let counter = 2; counter < 10000; counter += 1) {
    const candidateName = `${split.stem} (${counter})${split.ext}`;
    const candidate = dir ? joinPath(dir, candidateName) : candidateName;
    if (!claimedRelativePaths.has(candidate)) {
      claimedRelativePaths.add(candidate);
      return candidate;
    }
  }
  throw new Error(`Could not allocate unique tracked path for ${preferred}`);
}

function addKlmsTimestampFields(target, entry) {
  target.klms_timestamp = String(entry.klms_timestamp || "");
  target.klms_timestamp_text = String(entry.klms_timestamp_text || "");
  target.klms_timestamp_precision = String(entry.klms_timestamp_precision || "");
  target.klms_timestamp_label = String(entry.klms_timestamp_label || "");
  target.klms_timestamp_source = String(entry.klms_timestamp_source || "");
  target.klms_timestamp_basis = String(entry.klms_timestamp_basis || "klms_page");

  const epoch = Number(entry.klms_timestamp_epoch);
  target.klms_timestamp_epoch = Number.isFinite(epoch) ? Math.trunc(epoch) : null;
}

function buildLocalDownloadMetadataIndex(downloadLog) {
  const index = {};
  const results =
    downloadLog && typeof downloadLog === "object" && Array.isArray(downloadLog.results)
      ? downloadLog.results
      : [];

  results.forEach((result) => {
    const metadata = normalizeLocalDownloadMetadata(result, "");
    if (!metadata) {
      return;
    }
    const keys = [
      reusableFileKey(result.url, result.filename),
      reusableUrlKey(result.url),
    ].filter(Boolean);
    keys.forEach((key) => {
      if (!index[key]) {
        index[key] = metadata;
      }
    });
  });

  return index;
}

function resolveLocalDownloadMetadata(entry, localDownloadMetadataIndex, fallbackPath, fallbackBasis) {
  return (
    localDownloadMetadataForEntry(entry, localDownloadMetadataIndex) ||
    normalizeLocalDownloadMetadata(entry, "") ||
    fileCreationLocalDownloadMetadata(fallbackPath, fallbackBasis) ||
    currentLocalDownloadMetadata(fallbackBasis)
  );
}

function localDownloadMetadataForEntry(entry, localDownloadMetadataIndex) {
  const keys = [
    reusableFileKey(entry && entry.url, entry && entry.filename),
    reusableUrlKey(entry && entry.url),
  ].filter(Boolean);

  for (const key of keys) {
    if (localDownloadMetadataIndex && localDownloadMetadataIndex[key]) {
      return localDownloadMetadataIndex[key];
    }
  }
  return null;
}

function normalizeLocalDownloadMetadata(value, fallbackBasis) {
  if (!value || typeof value !== "object") {
    return null;
  }

  const epoch = Number(value.local_downloaded_epoch);
  const hasEpoch = Number.isFinite(epoch) && epoch > 0;
  const downloadedAt = String(value.local_downloaded_at || "").trim();
  if (!hasEpoch && !downloadedAt) {
    return null;
  }

  return {
    local_downloaded_at: downloadedAt || formatLocalTimestampFromEpoch(epoch),
    local_downloaded_epoch: hasEpoch ? Math.trunc(epoch) : null,
    local_downloaded_basis: String(value.local_downloaded_basis || fallbackBasis || "unknown"),
  };
}

function currentLocalDownloadMetadata(basis) {
  const epoch = Math.trunc(Date.now() / 1000);
  return {
    local_downloaded_at: formatLocalTimestampFromEpoch(epoch),
    local_downloaded_epoch: epoch,
    local_downloaded_basis: String(basis || "current-run"),
  };
}

function fileCreationLocalDownloadMetadata(path, basis) {
  const epoch = fileDateEpoch(path, $.NSFileCreationDate);
  if (!Number.isFinite(epoch) || epoch <= 0) {
    return null;
  }
  return {
    local_downloaded_at: formatLocalTimestampFromEpoch(epoch),
    local_downloaded_epoch: Math.trunc(epoch),
    local_downloaded_basis: String(basis || "file-creation"),
  };
}

function fileDateEpoch(path, attributeKey) {
  const normalizedPath = standardizeOptionalPath(path);
  if (!normalizedPath || !fileExists(normalizedPath)) {
    return 0;
  }

  const error = Ref();
  const attributes = $.NSFileManager.defaultManager.attributesOfItemAtPathError(
    $(normalizedPath).stringByStandardizingPath,
    error
  );
  if (!attributes) {
    return 0;
  }

  const dateValue = ObjC.deepUnwrap(attributes.objectForKey(attributeKey));
  if (dateValue && typeof dateValue.timeIntervalSince1970 === "function") {
    return Math.trunc(Number(dateValue.timeIntervalSince1970()));
  }
  return 0;
}

function formatLocalTimestampFromEpoch(epoch) {
  const normalizedEpoch = Number(epoch);
  if (!Number.isFinite(normalizedEpoch) || normalizedEpoch <= 0) {
    return "";
  }

  const formatter = $.NSDateFormatter.alloc.init;
  formatter.locale = $.NSLocale.localeWithLocaleIdentifier("en_US_POSIX");
  formatter.timeZone = $.NSTimeZone.timeZoneWithName("Asia/Seoul");
  formatter.dateFormat = "yyyy-MM-dd HH:mm 'KST'";
  return ObjC.unwrap(
    formatter.stringFromDate($.NSDate.dateWithTimeIntervalSince1970(Math.trunc(normalizedEpoch)))
  );
}

function applyLocalDownloadMetadata(entry, metadata) {
  if (!entry || !metadata) {
    return;
  }
  addLocalDownloadMetadataFields(entry, metadata);
}

function addLocalDownloadMetadataFields(target, metadata) {
  if (!target || !metadata) {
    return;
  }
  target.local_downloaded_at = String(metadata.local_downloaded_at || "");
  target.local_downloaded_basis = String(metadata.local_downloaded_basis || "unknown");

  const epoch = Number(metadata.local_downloaded_epoch);
  target.local_downloaded_epoch = Number.isFinite(epoch) && epoch > 0 ? Math.trunc(epoch) : null;
}

function applyKlmsTimestampToPaths(paths, entry) {
  const epoch = Number(entry && entry.klms_timestamp_epoch);
  if (!Number.isFinite(epoch) || epoch <= 0) {
    return;
  }

  const timestamp = $.NSDate.dateWithTimeIntervalSince1970(epoch);
  const attributes = $({
    NSFileModificationDate: timestamp,
  });

  paths.forEach((candidatePath) => {
    const normalizedPath = standardizeOptionalPath(candidatePath);
    if (!normalizedPath || !isRegularFile(normalizedPath)) {
      return;
    }
    const error = Ref();
    const ok = $.NSFileManager.defaultManager.setAttributesOfItemAtPathError(
      attributes,
      $(normalizedPath),
      error
    );
    if (!ok) {
      throw new Error(`Failed to set KLMS timestamp for ${normalizedPath}: ${unwrapError(error)}`);
    }
  });
}

function buildRecordedFilenameIndex(downloadLog) {
  const index = {};
  const results =
    downloadLog && typeof downloadLog === "object" && Array.isArray(downloadLog.results)
      ? downloadLog.results
      : [];
  const ambiguousFilenames = ambiguousRecordedFilenames(results);

  results.forEach((result) => {
    if (!downloadLogFilenameReuseAllowed(result, ambiguousFilenames)) {
      return;
    }
    const key = reusableUrlKey(result.url);
    const filename = String(
      result.filename || baseName(result.downloads_path || "") || baseName(result.destination_path || "")
    ).trim();
    if (isTransientDownloadName(filename)) {
      return;
    }
    if (key && filename && !index[key]) {
      index[key] = filename;
    }
  });

  return index;
}

function recordedFilenameForEntry(entry, recordedFilenameIndex) {
  const key = reusableUrlKey(entry && entry.url);
  if (!key) {
    return "";
  }
  const recordedFilename = String(recordedFilenameIndex[key] || "").trim();
  return filenameCompatibleWithExpected(recordedFilename, entry && entry.filename)
    ? recordedFilename
    : "";
}

function filenameCompatibleWithExpected(filename, expectedFilename) {
  const expected = String(expectedFilename || "").trim();
  const actual = String(filename || "").trim();
  if (!actual) {
    return false;
  }
  if (!expected || actual === expected || isCandidateFilename(actual, expected)) {
    return true;
  }

  const expectedFamily = extensionFamily(fileExtension(expected));
  const actualFamily = extensionFamily(fileExtension(actual));
  if (!expectedFamily || !actualFamily) {
    return true;
  }
  return expectedFamily === actualFamily;
}

function fileExtension(filename) {
  const name = baseName(filename).toLowerCase();
  const index = name.lastIndexOf(".");
  return index >= 0 ? name.slice(index) : "";
}

function extensionFamily(extension) {
  const ext = String(extension || "").toLowerCase();
  if (ext === ".ppt" || ext === ".pptx") {
    return "presentation";
  }
  if (ext === ".doc" || ext === ".docx") {
    return "document";
  }
  if (ext === ".xls" || ext === ".xlsx") {
    return "spreadsheet";
  }
  return ext;
}

function syncManifestStateEntries(manifestState, manifest) {
  if (!manifestState || typeof manifestState !== "object") {
    return;
  }
  if (!manifestState.sources || typeof manifestState.sources !== "object") {
    return;
  }

  const entriesBySource = {};
  manifest.forEach((entry) => {
    const sourceUrl = String(entry.source_url || "").trim();
    if (!sourceUrl) {
      return;
    }
    if (!entriesBySource[sourceUrl]) {
      entriesBySource[sourceUrl] = [];
    }
    entriesBySource[sourceUrl].push(JSON.parse(JSON.stringify(entry)));
  });

  Object.keys(manifestState.sources).forEach((sourceUrl) => {
    const sourceState = manifestState.sources[sourceUrl];
    if (!sourceState || typeof sourceState !== "object") {
      return;
    }
    sourceState.entries = entriesBySource[sourceUrl] || [];
  });
}

function waitForDownloadedFile(
  downloadsDir,
  beforeEntries,
  beforeEntrySignatures,
  expectedFilename,
  timeoutSeconds,
  allowAnyDownload
) {
  const deadline = Date.now() + timeoutSeconds * 1000;
  while (Date.now() < deadline) {
    delay(0.5);
    const afterEntries = listDirectory(downloadsDir);
    const candidates = afterEntries.filter((name) => {
      if (isIgnoredDownloadName(name)) {
        return false;
      }
      const fullPath = joinPath(downloadsDir, name);
      const signature = entrySignature(fullPath);
      const beforeSignature = beforeEntrySignatures[name] || "";
      if (beforeEntries.has(name) && beforeSignature === signature) {
        return false;
      }
      if (allowAnyDownload) {
        return freshDownloadFilenameMatchesExpected(name, expectedFilename);
      }
      return isCandidateFilename(name, expectedFilename);
    });
    const finalCandidates = candidates.filter((name) => !name.endsWith(".download"));
    for (const candidate of finalCandidates.filter((name) => !isTransientDownloadName(name))) {
      const fullPath = joinPath(downloadsDir, candidate);
      if (isStableFile(fullPath)) {
        return fullPath;
      }
    }
    for (const candidate of finalCandidates.filter((name) => isTransientDownloadName(name))) {
      const fullPath = joinPath(downloadsDir, candidate);
      if (isStableFile(fullPath)) {
        return fullPath;
      }
    }
  }
  return "";
}

function freshDownloadFilenameMatchesExpected(filename, expectedFilename) {
  const actual = String(filename || "").trim();
  const expected = String(expectedFilename || "").trim();
  if (!actual || isTransientDownloadName(actual)) {
    return false;
  }
  if (!expected) {
    return true;
  }
  return isCandidateFilename(actual, expected);
}

function retryInlineResourceDownload(
  windowRef,
  downloadsDir,
  beforeEntries,
  beforeEntrySignatures,
  expectedFilename,
  timeoutSeconds
) {
  const inlineUrl = currentTabUrl(windowRef);
  if (!inlineUrl || inlineUrl.includes("/login/")) {
    return "";
  }

  const retryUrl = withForcedDownload(inlineUrl);
  if (!retryUrl) {
    return "";
  }

  const tab = safeValue(() => windowRef.currentTab());
  if (!tab) {
    return "";
  }

  navigateTabWithoutFocus(tab, retryUrl);
  delay(0.5);
  return waitForDownloadedFile(
    downloadsDir,
    beforeEntries,
    beforeEntrySignatures,
    expectedFilename,
    timeoutSeconds,
    true
  );
}

function waitForAutoUnzippedArchive(downloadsDir, beforeEntries, expectedFilename, timeoutSeconds) {
  const expected = splitFileName(expectedFilename);
  if (expected.ext !== ".zip") {
    return { path: "", auxiliaryPaths: [] };
  }

  const deadline = Date.now() + Math.max(2, timeoutSeconds) * 1000;
  while (Date.now() < deadline) {
    const extractedDir = findExtractedArchiveDirectory(downloadsDir, beforeEntries, expected.stem);
    if (extractedDir && isStableDirectoryTree(extractedDir)) {
      const recoveredZipPath = joinPath(downloadsDir, expectedFilename);
      createZipFromDirectory(extractedDir, recoveredZipPath);
      if (isStableFile(recoveredZipPath)) {
        return {
          path: recoveredZipPath,
          auxiliaryPaths: [extractedDir],
        };
      }
    }
    delay(0.5);
  }

  return { path: "", auxiliaryPaths: [] };
}

function canDirectFetchKlmsFile(url) {
  const text = String(url || "").trim();
  return text.includes("klms.kaist.ac.kr/pluginfile.php/");
}

function isIgnoredDownloadName(name) {
  const text = String(name || "").trim();
  if (!text) {
    return true;
  }
  return text === ".DS_Store" || text.startsWith("._") || text.startsWith(".");
}

function fetchKlmsFileViaSafari(windowRef, targetUrl, backupRoot, fileIndex, expectedFilename) {
  if (!windowRef || !targetUrl) {
    return "";
  }

  waitForHtmlDocumentReady(windowRef, 10);
  const payload = fetchBinaryPayloadViaSafari(windowRef, targetUrl);
  if (!payload.ok || !payload.base64 || !fetchedPayloadCompatibleWithExpected(payload)) {
    return "";
  }
  const resolvedFilename = resolveFetchedFilename(payload, targetUrl, expectedFilename);

  const tempRoot = joinPath(
    backupRoot,
    `direct-${String(fileIndex).padStart(3, "0")}-${sanitizeFileComponent(baseName(resolvedFilename))}-${Date.now()}`
  );
  ensureDir(tempRoot);
  const outputPath = joinPath(tempRoot, baseName(resolvedFilename));
  writeBase64File(payload.base64, outputPath);
  return isRegularFile(outputPath) && fileSize(outputPath) > 0 ? outputPath : "";
}

function resolveFetchedFilename(payload, targetUrl, expectedFilename) {
  return (
    extractFilenameFromContentDisposition(payload && payload.contentDisposition) ||
    extractFilenameFromUrl(payload && payload.responseUrl) ||
    extractFilenameFromUrl(targetUrl) ||
    String(expectedFilename || "").trim() ||
    "attachment"
  );
}

function fetchedPayloadCompatibleWithExpected(payload) {
  const contentType = String(payload && payload.contentType || "").toLowerCase();
  const headText = String(payload && payload.headText || "").trim().toLowerCase();
  return !(
    contentType.includes("text/html") ||
    headText.startsWith("<!doctype html") ||
    headText.startsWith("<html")
  );
}

function extractFilenameFromContentDisposition(value) {
  const text = String(value || "").trim();
  if (!text) {
    return "";
  }

  const encodedMatch = text.match(/filename\*\s*=\s*([^;]+)/i);
  if (encodedMatch) {
    const encodedValue = String(encodedMatch[1] || "")
      .trim()
      .replace(/^UTF-8''/i, "")
      .replace(/^"(.*)"$/, "$1");
    try {
      return sanitizeDownloadFilename(decodeURIComponent(encodedValue));
    } catch (_error) {
      return sanitizeDownloadFilename(encodedValue);
    }
  }

  const plainMatch = text.match(/filename\s*=\s*([^;]+)/i);
  if (!plainMatch) {
    return "";
  }
  return sanitizeDownloadFilename(String(plainMatch[1] || "").trim().replace(/^"(.*)"$/, "$1"));
}

function extractFilenameFromUrl(url) {
  const text = String(url || "").trim();
  if (!text) {
    return "";
  }
  const stripped = text.replace(/[?#].*$/, "");
  const rawName = stripped.slice(stripped.lastIndexOf("/") + 1);
  if (!rawName || /^pluginfile\.php$/i.test(rawName) || /^view\.php$/i.test(rawName)) {
    return "";
  }
  try {
    return sanitizeDownloadFilename(decodeURIComponent(rawName));
  } catch (_error) {
    return sanitizeDownloadFilename(rawName);
  }
}

function sanitizeDownloadFilename(value) {
  return String(value || "")
    .trim()
    .replace(/[\/:]+/g, "-")
    .replace(/\s+/g, " ");
}

function waitForHtmlDocumentReady(windowRef, timeoutSeconds) {
  const deadline = Date.now() + Math.max(3, timeoutSeconds) * 1000;
  while (Date.now() < deadline) {
    const state = getHtmlDocumentReadyState(windowRef);
    if (state.ready) {
      return true;
    }
    delay(0.5);
  }
  return false;
}

function getHtmlDocumentReadyState(windowRef) {
  const script = [
    "(function(){",
    "  try {",
    "    return JSON.stringify({",
    "      ready: document.readyState === 'complete' && !!document.body,",
    "      readyState: document.readyState || '',",
    "      title: document.title || ''",
    "    });",
    "  } catch (error) {",
    "    return JSON.stringify({ready:false,error:String(error)});",
    "  }",
    "})()",
  ].join("\n");
  const result = runSafariJavaScript(windowRef, script);
  if (result == null) {
    return { ready: false };
  }
  try {
    return JSON.parse(String(result));
  } catch (_error) {
    return { ready: false };
  }
}

function fetchBinaryPayloadViaSafari(windowRef, targetUrl) {
  const script = [
    "(function(){",
    `  var targetUrl = ${JSON.stringify(targetUrl)};`,
    "  function bytesToBase64(bytes) {",
    "    var chunkSize = 0x8000;",
    "    var parts = [];",
    "    for (var offset = 0; offset < bytes.length; offset += chunkSize) {",
    "      parts.push(String.fromCharCode.apply(null, bytes.subarray(offset, offset + chunkSize)));",
    "    }",
    "    return btoa(parts.join(''));",
    "  }",
    "  function bytesToAsciiPreview(bytes) {",
    "    var length = Math.min(bytes.length, 128);",
    "    var parts = [];",
    "    for (var index = 0; index < length; index += 1) {",
    "      var value = bytes[index];",
    "      if ((value >= 32 && value <= 126) || value === 9 || value === 10 || value === 13) {",
    "        parts.push(String.fromCharCode(value));",
    "      } else {",
    "        parts.push('.');",
    "      }",
    "    }",
    "    return parts.join('');",
    "  }",
    "  try {",
    "    var xhr = new XMLHttpRequest();",
    "    xhr.open('GET', targetUrl, false);",
    "    xhr.responseType = 'arraybuffer';",
    "    xhr.send(null);",
    "    var status = xhr.status || 0;",
    "    if (status >= 400) {",
    "      return JSON.stringify({ok:false,status:status,error:'http-'+status});",
    "    }",
    "    var bytes = new Uint8Array(xhr.response || new ArrayBuffer(0));",
    "    if (!bytes.length) {",
    "      return JSON.stringify({ok:false,status:status,error:'empty-body'});",
    "    }",
    "    return JSON.stringify({",
    "      ok: true,",
    "      status: status,",
    "      responseUrl: xhr.responseURL || '',",
    "      contentDisposition: xhr.getResponseHeader('Content-Disposition') || '',",
    "      contentType: xhr.getResponseHeader('Content-Type') || '',",
    "      headText: bytesToAsciiPreview(bytes),",
    "      base64: bytesToBase64(bytes)",
    "    });",
    "  } catch (error) {",
    "    return JSON.stringify({ok:false,error:String(error)});",
    "  }",
    "})()",
  ].join("\n");
  const result = runSafariJavaScript(windowRef, script);
  if (result == null) {
    return { ok: false, error: "empty-result" };
  }
  try {
    return JSON.parse(String(result));
  } catch (error) {
    return { ok: false, error: String(error) };
  }
}

function recoverSynapViewerPdf(
  windowRef,
  expectedFilename,
  backupRoot,
  projectRoot,
  fileIndex,
  timeoutSeconds,
  initialViewerUrl
) {
  if (!windowRef || !/\.pdf$/i.test(String(expectedFilename || "").trim())) {
    return "";
  }

  const viewerUrl = String(initialViewerUrl || extractSynapViewerUrl(windowRef) || "").trim();
  if (!viewerUrl) {
    return "";
  }

  const tab = safeValue(() => windowRef.currentTab());
  if (!tab) {
    return "";
  }

  navigateTabWithoutFocus(tab, viewerUrl);
  delay(0.5);
  const viewerState = waitForSynapViewer(windowRef, timeoutSeconds);
  if (!viewerState.ready || viewerState.pageCount <= 0) {
    return "";
  }

  const tempRoot = joinPath(
    backupRoot,
    `synap-${String(fileIndex).padStart(3, "0")}-${sanitizeFileComponent(baseName(expectedFilename))}-${Date.now()}`
  );
  ensureDir(tempRoot);

  const imagePaths = [];
  for (let pageIndex = 0; pageIndex < viewerState.pageCount; pageIndex += 1) {
    const pagePayload = extractSynapViewerPage(windowRef, pageIndex);
    if (!pagePayload.ok || !pagePayload.base64) {
      throw new Error(
        `Failed to extract Synap page ${pageIndex + 1}/${viewerState.pageCount}: ${pagePayload.error || "unknown error"}`
      );
    }
    const imagePath = joinPath(tempRoot, `${String(pageIndex + 1).padStart(4, "0")}.png`);
    writeBase64File(pagePayload.base64, imagePath);
    imagePaths.push(imagePath);
  }

  const recoveredPdfPath = joinPath(tempRoot, baseName(expectedFilename));
  buildPdfFromImages(projectRoot, recoveredPdfPath, imagePaths);
  if (!isRegularFile(recoveredPdfPath) || fileSize(recoveredPdfPath) <= 0) {
    throw new Error(`Failed to rebuild PDF from Synap viewer: ${expectedFilename}`);
  }
  return recoveredPdfPath;
}

function extractSynapViewerUrl(windowRef) {
  const script = [
    "(function(){",
    '  var anchor = document.querySelector(".resourceworkaround a");',
    '  if (!anchor) { return ""; }',
    '  var onclick = String(anchor.getAttribute("onclick") || "");',
    "  var match = onclick.match(/window\\.open\\('([^']+)'/);",
    '  return match ? match[1] : "";',
    "})()",
  ].join("\n");
  const result = runSafariJavaScript(windowRef, script);
  return result == null ? "" : String(result).trim();
}

function waitForSynapViewer(windowRef, timeoutSeconds) {
  const deadline = Date.now() + Math.max(5, timeoutSeconds) * 1000;
  while (Date.now() < deadline) {
    const state = getSynapViewerState(windowRef);
    if (state.ready) {
      return state;
    }
    delay(1);
  }
  return { ready: false, pageCount: 0, title: "" };
}

function getSynapViewerState(windowRef) {
  const script = [
    "(function(){",
    '  var images = Array.from(document.querySelectorAll("img.contents-page__img"));',
    '  var ready = document.title.indexOf("문서뷰어") >= 0 && images.length > 0 && images.every(function(img){',
    "    return !!img.complete && img.naturalWidth > 0 && img.naturalHeight > 0;",
    "  });",
    "  return JSON.stringify({",
    "    ready: ready,",
    "    pageCount: images.length,",
    "    title: document.title || ''",
    "  });",
    "})()",
  ].join("\n");
  const result = runSafariJavaScript(windowRef, script);
  if (result == null) {
    return { ready: false, pageCount: 0, title: "" };
  }
  try {
    const parsed = JSON.parse(String(result));
    return {
      ready: Boolean(parsed.ready),
      pageCount: Number(parsed.pageCount || 0),
      title: String(parsed.title || ""),
    };
  } catch (_error) {
    return { ready: false, pageCount: 0, title: "" };
  }
}

function extractSynapViewerPage(windowRef, pageIndex) {
  const script = [
    "(function(){",
    `  var image = document.getElementById("page${pageIndex}");`,
    '  if (!image) { return JSON.stringify({ok:false,error:"page-not-found"}); }',
    '  if (!image.complete || image.naturalWidth <= 0 || image.naturalHeight <= 0) {',
    '    return JSON.stringify({ok:false,error:"page-not-ready"});',
    "  }",
    '  var xhr = new XMLHttpRequest();',
    '  xhr.open("GET", image.src, false);',
    '  xhr.responseType = "arraybuffer";',
    "  xhr.send(null);",
    "  if (xhr.status && xhr.status >= 400) {",
    '    return JSON.stringify({ok:false,error:"http-"+xhr.status});',
    "  }",
    "  var bytes = new Uint8Array(xhr.response || new ArrayBuffer(0));",
    "  var chunkSize = 0x8000;",
    "  var parts = [];",
    "  for (var offset = 0; offset < bytes.length; offset += chunkSize) {",
    "    parts.push(String.fromCharCode.apply(null, bytes.subarray(offset, offset + chunkSize)));",
    "  }",
    "  return JSON.stringify({",
    "    ok: true,",
    "    width: image.naturalWidth,",
    "    height: image.naturalHeight,",
    "    base64: btoa(parts.join(''))",
    "  });",
    "})()",
  ].join("\n");
  const result = runSafariJavaScript(windowRef, script);
  if (result == null) {
    return { ok: false, error: "empty-result" };
  }
  try {
    return JSON.parse(String(result));
  } catch (error) {
    return { ok: false, error: String(error) };
  }
}

function recoverAutoUnzippedArchive(downloadsDir, beforeEntries, expectedFilename) {
  const expected = splitFileName(expectedFilename);
  if (expected.ext !== ".zip") {
    return { path: "", auxiliaryPaths: [] };
  }

  const extractedDir = findExtractedArchiveDirectory(downloadsDir, beforeEntries, expected.stem);
  if (!extractedDir) {
    return { path: "", auxiliaryPaths: [] };
  }

  const recoveredZipPath = joinPath(downloadsDir, expectedFilename);
  createZipFromDirectory(extractedDir, recoveredZipPath);
  if (!isStableFile(recoveredZipPath)) {
    return { path: "", auxiliaryPaths: [] };
  }

  return {
    path: recoveredZipPath,
    auxiliaryPaths: [extractedDir],
  };
}

function findExtractedArchiveDirectory(downloadsDir, beforeEntries, expectedStem) {
  const afterEntries = listDirectory(downloadsDir);
  const candidates = afterEntries.filter((name) => archiveStemMatches(name, expectedStem));

  const prioritizedCandidates = candidates.sort((lhs, rhs) => {
    const leftWasPresent = beforeEntries.has(lhs) ? 1 : 0;
    const rightWasPresent = beforeEntries.has(rhs) ? 1 : 0;
    return leftWasPresent - rightWasPresent;
  });

  for (const candidate of prioritizedCandidates) {
    const fullPath = joinPath(downloadsDir, candidate);
    if (isDirectory(fullPath)) {
      return fullPath;
    }
  }

  return "";
}

function isStableDirectoryTree(path) {
  const first = directoryTreeSignature(path);
  if (!first) {
    return false;
  }
  delay(0.5);
  return first === directoryTreeSignature(path);
}

function directoryTreeSignature(rootPath) {
  if (!isDirectory(rootPath)) {
    return "";
  }

  const signatures = [];
  collectDirectoryTreeSignature(rootPath, "", signatures);
  return signatures.join("|");
}

function collectDirectoryTreeSignature(rootPath, relativeRoot, signatures) {
  const names = listDirectory(rootPath).sort();
  names.forEach((name) => {
    if (isIgnoredDownloadName(name)) {
      return;
    }
    const fullPath = joinPath(rootPath, name);
    const relativePath = relativeRoot ? `${relativeRoot}/${name}` : name;
    if (isDirectory(fullPath)) {
      signatures.push(`dir:${relativePath}`);
      collectDirectoryTreeSignature(fullPath, relativePath, signatures);
      return;
    }
    signatures.push(`file:${relativePath}:${entrySignature(fullPath)}`);
  });
}

function archiveStemMatches(candidate, expectedStem) {
  if (!candidate || !expectedStem) {
    return false;
  }

  return (
    candidate === expectedStem ||
    candidate.startsWith(`${expectedStem} `) ||
    candidate.startsWith(`${expectedStem} (`)
  );
}

function createZipFromDirectory(sourceDir, destinationZipPath) {
  removeFileIfExists(destinationZipPath);
  runProcess([
    "/usr/bin/ditto",
    "-c",
    "-k",
    "--sequesterRsrc",
    "--keepParent",
    sourceDir,
    destinationZipPath,
  ]);
}

function buildPdfFromImages(projectRoot, outputPdfPath, imagePaths) {
  if (!imagePaths.length) {
    throw new Error(`No image paths provided for PDF rebuild: ${outputPdfPath}`);
  }
  const helperPath = findPdfBuildHelper(projectRoot);
  if (!helperPath) {
    throw new Error(`Missing PDF build helper under: ${projectRoot}`);
  }
  runProcess(
    [
      resolveExecutable("python3", "/usr/bin/python3"),
      helperPath,
      outputPdfPath,
    ].concat(imagePaths)
  );
}

function findPdfBuildHelper(projectRoot) {
  const candidates = [
    joinPath(projectRoot, "build_pdf_from_images.py"),
    joinPath(projectRoot, "src/python/build_pdf_from_images.py"),
  ];
  return candidates.find((candidate) => fileExists(candidate)) || "";
}

function resolveExecutable(name, fallbackPath) {
  const envPath = processEnvironmentValue("PATH");
  for (const dir of envPath.split(":")) {
    const candidate = standardizeOptionalPath(joinPath(dir, name));
    if (candidate && isRegularFile(candidate)) {
      return candidate;
    }
  }
  return fallbackPath;
}

function processEnvironmentValue(name) {
  const value = $.NSProcessInfo.processInfo.environment.objectForKey($(name));
  return value ? String(ObjC.unwrap(value)) : "";
}

function writeBase64File(base64Text, destinationPath) {
  const data = $.NSData.alloc.initWithBase64EncodedStringOptions($(String(base64Text)), 0);
  if (!data) {
    throw new Error(`Failed to decode base64 payload for ${destinationPath}`);
  }
  const error = Ref();
  const ok = data.writeToFileOptionsError(
    $(destinationPath).stringByStandardizingPath,
    0,
    error
  );
  if (!ok) {
    throw new Error(`Failed to write ${destinationPath}: ${unwrapError(error)}`);
  }
}

function isCandidateFilename(candidate, expectedFilename) {
  if (!candidate || !expectedFilename) {
    return false;
  }
  if (isTransientDownloadName(candidate)) {
    return false;
  }

  if (candidate === expectedFilename) {
    return true;
  }

  const expected = splitFileName(expectedFilename);
  const actual = splitFileName(candidate.replace(/\.download$/, ""));
  if (expected.ext !== actual.ext) {
    return false;
  }

  return (
    actual.stem === expected.stem ||
    actual.stem.startsWith(`${expected.stem} `) ||
    actual.stem.startsWith(`${expected.stem} (`)
  );
}

function isStableFile(path) {
  if (!isRegularFile(path)) {
    return false;
  }
  const first = fileSize(path);
  if (!first) {
    return false;
  }
  delay(0.5);
  return first === fileSize(path);
}

function splitFileName(name) {
  const index = name.lastIndexOf(".");
  if (index <= 0) {
    return { stem: name, ext: "" };
  }
  return {
    stem: name.slice(0, index),
    ext: name.slice(index).toLowerCase(),
  };
}

function openReusableDownloadPage(safari, existingWindowRef, targetUrl) {
  const activeWindow =
    reusableWindowByReference(safari, existingWindowRef) ||
    findKlmsWindow(safari) ||
    createSafariWindow(safari, targetUrl);
  const tab = safeValue(() => activeWindow.currentTab());
  if (!tab) {
    throw new Error("Reusable Safari download window is missing a current tab");
  }

  if (targetUrl) {
    navigateTabWithoutFocus(tab, targetUrl);
    waitForWindowUrl(activeWindow, targetUrl, 8);
  }
  return activeWindow;
}

function navigateTabWithoutFocus(tab, targetUrl) {
  const frontmostApp = frontmostApplicationName();
  tab.url = targetUrl;
  restoreFrontmostApplication(frontmostApp);
}

function frontmostApplicationName() {
  try {
    const systemEvents = Application("System Events");
    const frontProcesses = systemEvents.applicationProcesses.whose({ frontmost: true })();
    return frontProcesses.length ? String(frontProcesses[0].name()) : "";
  } catch (_error) {
    return "";
  }
}

function restoreFrontmostApplication(appName) {
  if (!appName || appName === "Safari") {
    return;
  }
  try {
    Application(appName).activate();
  } catch (_error) {
    // If the previous app cannot be activated, leave Safari state as-is.
  }
}

function reusableWindowByReference(safari, existingWindowRef) {
  if (!existingWindowRef) {
    return null;
  }

  const windowId = safeNumber(() => existingWindowRef.id(), null);
  const windowRef = windowId == null ? existingWindowRef : findWindowById(safari, windowId);
  if (!windowRef || !safeValue(() => windowRef.currentTab())) {
    return null;
  }
  return windowRef;
}

function findKlmsWindow(safari) {
  return (
    safeList(() => safari.windows()).find((windowRef) =>
      currentTabUrl(windowRef).includes("klms.kaist.ac.kr")
    ) || null
  );
}

function createSafariWindow(safari, targetUrl) {
  const previousWindowIds = new Set(listWindowIds(safari));
  const openWindowCommand = [
    "/usr/bin/osascript",
    "-e",
    "on run argv",
    "-e",
    "if (count of argv) > 0 then",
    "-e",
    "tell application \"Safari\" to make new document with properties {URL:item 1 of argv}",
    "-e",
    "else",
    "-e",
    "tell application \"Safari\" to make new document",
    "-e",
    "end if",
    "-e",
    "end run",
  ];
  if (targetUrl) {
    openWindowCommand.push(String(targetUrl));
  }
  runProcess(openWindowCommand);

  const deadline = Date.now() + 5000;
  let activeWindow = null;
  while (Date.now() < deadline && !activeWindow) {
    delay(0.5);
    const windows = safeList(() => safari.windows());
    activeWindow =
      windows.find((windowRef) => !previousWindowIds.has(safeNumber(() => windowRef.id(), -1))) ||
      null;
  }
  if (!activeWindow) {
    throw new Error("Could not create reusable Safari download window");
  }
  return activeWindow;
}

function waitForWindowUrl(windowRef, targetUrl, timeoutSeconds) {
  const deadline = Date.now() + Math.max(2, timeoutSeconds) * 1000;
  while (Date.now() < deadline) {
    const currentUrl = currentTabUrl(windowRef);
    if (currentUrl && (!targetUrl || currentUrl === targetUrl || currentUrl.startsWith(targetUrl))) {
      return true;
    }
    delay(0.5);
  }
  return false;
}

function listWindowIds(safari) {
  return safeList(() => safari.windows())
    .map((windowRef) => safeNumber(() => windowRef.id(), null))
    .filter((windowId) => Number.isFinite(windowId));
}

function findWindowById(safari, windowId) {
  return (
    safeList(() => safari.windows()).find(
      (windowRef) => safeNumber(() => windowRef.id(), null) === windowId
    ) || null
  );
}

function currentTabUrl(windowRef) {
  const tab = safeValue(() => windowRef.currentTab());
  if (!tab) {
    return "";
  }
  const url = safeValue(() => tab.url());
  return url == null ? "" : String(url);
}

function resolveDirectFileUrlFromWindow(windowRef) {
  const currentUrl = currentTabUrl(windowRef);
  if (canDirectFetchKlmsFile(currentUrl)) {
    return currentUrl;
  }

  const script = [
    "(function(){",
    "  try {",
    "    var selectors = [",
    "      '.resourceworkaround a[href]',",
    "      'a.resourceworkaround[href]',",
    "      'a[href*=\"pluginfile.php\"]',",
    "      '.resourcecontent a[href]'",
    "    ];",
    "    for (var i = 0; i < selectors.length; i += 1) {",
    "      var node = document.querySelector(selectors[i]);",
    "      if (node && node.href) {",
    "        return String(node.href);",
    "      }",
    "    }",
    "    return '';",
    "  } catch (error) {",
    "    return '';",
    "  }",
    "})()",
  ].join("\n");
  const result = runSafariJavaScript(windowRef, script);
  return result == null ? "" : String(result).trim();
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

function readOptionalJson(path) {
  if (!fileExists(path)) {
    return null;
  }
  try {
    return readJson(path);
  } catch (_error) {
    return null;
  }
}

function writeJson(path, value) {
  const text = JSON.stringify(value, null, 2);
  const error = Ref();
  const ok = $(text).writeToFileAtomicallyEncodingError(
    $(path).stringByStandardizingPath,
    true,
    $.NSUTF8StringEncoding,
    error
  );
  if (!ok) {
    throw new Error(`Failed to write ${path}: ${unwrapError(error)}`);
  }
}

function listDirectory(path) {
  const error = Ref();
  const items = $.NSFileManager.defaultManager.contentsOfDirectoryAtPathError(
    $(path).stringByStandardizingPath,
    error
  );
  if (!items) {
    throw new Error(`Failed to read directory ${path}: ${unwrapError(error)}`);
  }
  const unwrapped = ObjC.deepUnwrap(items);
  return Array.isArray(unwrapped) ? unwrapped : [];
}

function buildDirectoryEntrySignatures(root, names) {
  const signatures = {};
  for (const name of names) {
    signatures[name] = entrySignature(joinPath(root, name));
  }
  return signatures;
}

function entrySignature(path) {
  const normalizedPath = standardizeOptionalPath(path);
  if (!normalizedPath || !fileExists(normalizedPath)) {
    return "";
  }
  const error = Ref();
  const attributes = $.NSFileManager.defaultManager.attributesOfItemAtPathError(
    $(normalizedPath).stringByStandardizingPath,
    error
  );
  if (!attributes) {
    return "";
  }
  const size = Number(ObjC.deepUnwrap(attributes.objectForKey($.NSFileSize)) || 0);
  const modifiedAt = ObjC.deepUnwrap(attributes.objectForKey($.NSFileModificationDate));
  const timestamp =
    modifiedAt && typeof modifiedAt.timeIntervalSince1970 === "function"
      ? Number(modifiedAt.timeIntervalSince1970())
      : 0;
  return `${size}:${timestamp}`;
}

function moveFile(src, dest) {
  removeFileIfExists(dest);
  const error = Ref();
  const ok = $.NSFileManager.defaultManager.moveItemAtPathToPathError(
    $(src).stringByStandardizingPath,
    $(dest).stringByStandardizingPath,
    error
  );
  if (!ok) {
    throw new Error(`Failed to move ${src} -> ${dest}: ${unwrapError(error)}`);
  }
}

function copyFile(src, dest) {
  removeFileIfExists(dest);
  const error = Ref();
  const ok = $.NSFileManager.defaultManager.copyItemAtPathToPathError(
    $(src).stringByStandardizingPath,
    $(dest).stringByStandardizingPath,
    error
  );
  if (!ok) {
    throw new Error(`Failed to copy ${src} -> ${dest}: ${unwrapError(error)}`);
  }
}

function preserveDownloadedCopy(downloadedPath, trackedPath) {
  ensureDir(directoryName(trackedPath));
  removeDirectoryArtifactIfExists(trackedPath);
  moveFile(downloadedPath, trackedPath);
  return trackedPath;
}

function buildLegacyDownloadAuxiliaryPaths(downloadsDir, trackedArchivePath, filename, expectedBytes) {
  const rootCandidate = standardizeOptionalPath(joinPath(downloadsDir, filename || ""));
  if (!rootCandidate || !isRegularFile(rootCandidate)) {
    return [];
  }
  if (samePath(rootCandidate, trackedArchivePath)) {
    return [];
  }
  if (isTransientDownloadName(baseName(rootCandidate))) {
    return [];
  }
  const normalizedExpectedBytes = Number(expectedBytes);
  if (
    Number.isFinite(normalizedExpectedBytes) &&
    normalizedExpectedBytes > 0 &&
    fileSize(rootCandidate) !== normalizedExpectedBytes
  ) {
    return [];
  }
  return [rootCandidate];
}

function claimAuxiliaryPaths(paths, claimedPaths) {
  const results = [];
  (Array.isArray(paths) ? paths : []).forEach((candidatePath) => {
    const normalizedPath = standardizeOptionalPath(candidatePath);
    if (!normalizedPath || claimedPaths.has(normalizedPath)) {
      return;
    }
    claimedPaths.add(normalizedPath);
    results.push(normalizedPath);
  });
  return results;
}

function ensureDir(path) {
  const normalizedPath = standardizeOptionalPath(path);
  if (!normalizedPath) {
    return;
  }
  const error = Ref();
  const ok = $.NSFileManager.defaultManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(
    $(normalizedPath),
    true,
    $.NSDictionary.dictionary,
    error
  );
  if (!ok) {
    throw new Error(`Failed to create directory ${normalizedPath}: ${unwrapError(error)}`);
  }
}

function fileSize(path) {
  if (!isRegularFile(path)) {
    return 0;
  }
  const error = Ref();
  const attributes = $.NSFileManager.defaultManager.attributesOfItemAtPathError(
    $(path).stringByStandardizingPath,
    error
  );
  if (!attributes) {
    return 0;
  }
  return Number(ObjC.deepUnwrap(attributes.objectForKey($.NSFileSize)) || 0);
}

function isDirectory(path) {
  const isDirectoryRef = Ref();
  const exists = $.NSFileManager.defaultManager.fileExistsAtPathIsDirectory(
    $(path).stringByStandardizingPath,
    isDirectoryRef
  );
  return Boolean(exists && ObjC.unwrap(isDirectoryRef[0]));
}

function isRegularFile(path) {
  const normalizedPath = standardizeOptionalPath(path);
  return Boolean(normalizedPath && fileExists(normalizedPath) && !isDirectory(normalizedPath));
}

function removeDirectoryArtifactIfExists(path) {
  const normalizedPath = standardizeOptionalPath(path);
  if (!normalizedPath || !isDirectory(normalizedPath)) {
    return;
  }
  removeFileIfExists(normalizedPath);
}

function removeFileIfExists(path) {
  const standardized = $(path).stringByStandardizingPath;
  if (!fileExists(path)) {
    return;
  }
  const error = Ref();
  const ok = $.NSFileManager.defaultManager.removeItemAtPathError(standardized, error);
  if (!ok) {
    throw new Error(`Failed to remove ${path}: ${unwrapError(error)}`);
  }
}

function fileExists(path) {
  return $.NSFileManager.defaultManager.fileExistsAtPath($(path).stringByStandardizingPath);
}

function standardizePath(path) {
  return ObjC.unwrap($(String(path).normalize("NFC")).stringByStandardizingPath);
}

function standardizeOptionalPath(path) {
  const text = String(path || "").trim();
  if (!text) {
    return "";
  }
  return standardizePath(text);
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

function jsonString(value) {
  return JSON.stringify(String(value));
}

function homeDirectory() {
  return ObjC.unwrap($.NSHomeDirectory());
}

function withForcedDownload(url) {
  if (!url) {
    return "";
  }
  if (/([?&])forcedownload=1(?:&|$)/i.test(url)) {
    return url;
  }
  return url.includes("?") ? `${url}&forcedownload=1` : `${url}?forcedownload=1`;
}

function shellQuote(value) {
  const text = String(value);
  return `'${text.replace(/'/g, `'\"'\"'`)}'`;
}

function buildReusableFileIndex(downloadLog) {
  const index = {};
  const results =
    downloadLog && typeof downloadLog === "object" && Array.isArray(downloadLog.results)
      ? downloadLog.results
      : [];
  const ambiguousFilenames = ambiguousRecordedFilenames(results);

  results.forEach((result) => {
    if (!downloadLogFilenameReuseAllowed(result, ambiguousFilenames)) {
      return;
    }
    if (isTransientDownloadName(result.filename || "")) {
      return;
    }
    const keys = [reusableFileKey(result.url, result.filename), reusableUrlKey(result.url)].filter(
      Boolean
    );
    if (keys.length === 0) {
      return;
    }
    [result.destination_path, result.downloads_path].forEach((candidatePath) => {
      const normalizedPath = standardizeOptionalPath(candidatePath);
      if (!normalizedPath) {
        return;
      }
      if (!isRegularFile(normalizedPath)) {
        return;
      }
      if (isTransientDownloadName(baseName(normalizedPath))) {
        return;
      }
      keys.forEach((key) => {
        if (!index[key]) {
          index[key] = [];
        }
        if (!index[key].includes(normalizedPath)) {
          index[key].push(normalizedPath);
        }
      });
    });
  });

  return index;
}

function findReusableSourcePath(index, entry, destinationPath, trackedArchivePath) {
  const candidateKeys = [
    { key: reusableFileKey(entry.url, entry.filename), requireCompatibleFilename: false },
    { key: reusableUrlKey(entry.url), requireCompatibleFilename: true },
  ].filter((candidate) => candidate.key);

  for (const candidateKey of candidateKeys) {
    const key = candidateKey.key;
    if (!index[key]) {
      continue;
    }
    const reusablePath =
      index[key].find((candidatePath) => {
        if (!candidatePath || !isRegularFile(candidatePath)) {
          return false;
        }
        if (samePath(candidatePath, destinationPath) || samePath(candidatePath, trackedArchivePath)) {
          return false;
        }
        if (
          candidateKey.requireCompatibleFilename &&
          !filenameCompatibleWithExpected(baseName(candidatePath), entry.filename)
        ) {
          return false;
        }
        return true;
      }) || "";
    if (reusablePath) {
      return reusablePath;
    }
  }
  return "";
}

function ambiguousRecordedFilenames(results) {
  const ownersByFilename = {};
  results.forEach((result) => {
    const filename = String(
      result && (result.filename || baseName(result.downloads_path || "") || baseName(result.destination_path || ""))
    ).trim();
    if (!filename || isTransientDownloadName(filename)) {
      return;
    }
    const owner = `${String(result.course || "")}\n${String(result.source_url || "")}`;
    if (!ownersByFilename[filename]) {
      ownersByFilename[filename] = new Set();
    }
    ownersByFilename[filename].add(owner);
  });

  const ambiguous = new Set();
  Object.keys(ownersByFilename).forEach((filename) => {
    if (ownersByFilename[filename].size > 1) {
      ambiguous.add(filename);
    }
  });
  return ambiguous;
}

function downloadLogFilenameReuseAllowed(result, ambiguousFilenames) {
  const filename = String(
    result && (result.filename || baseName(result.downloads_path || "") || baseName(result.destination_path || ""))
  ).trim();
  if (!filename || isTransientDownloadName(filename)) {
    return false;
  }
  if (String(result && result.manifest_filename || "").trim() === filename) {
    return true;
  }
  return !(ambiguousFilenames && ambiguousFilenames.has(filename));
}

function reusableFileKey(url, filename) {
  const normalizedUrl = stripForcedDownloadFlag(url);
  const normalizedFilename = String(filename || "").trim().toLowerCase();
  if (!normalizedUrl || !normalizedFilename) {
    return "";
  }
  return `${normalizedUrl}::${normalizedFilename}`;
}

function reusableUrlKey(url) {
  const normalizedUrl = stripForcedDownloadFlag(url);
  if (!normalizedUrl) {
    return "";
  }
  return `${normalizedUrl}::*`;
}

function stripForcedDownloadFlag(url) {
  return String(url || "")
    .trim()
    .replace(/([?&])forcedownload=1&/gi, "$1")
    .replace(/[?&]forcedownload=1$/gi, "")
    .replace(/\?&/g, "?")
    .replace(/[?&]$/g, "");
}

function samePath(lhs, rhs) {
  const left = standardizeOptionalPath(lhs);
  const right = standardizeOptionalPath(rhs);
  return Boolean(left && right && left === right);
}

function isTransientDownloadName(name) {
  const text = String(name || "").trim().toLowerCase();
  if (!text) {
    return false;
  }
  return (
    text.endsWith(".download") ||
    text.endsWith(".drivedownload") ||
    text === ".tmp.drivedownload" ||
    text.startsWith(".tmp.")
  );
}

function sanitizeFileComponent(value) {
  return String(value || "")
    .trim()
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "") || "file";
}

function findProjectRoot(manifestPath, outputRoot) {
  const candidates = [
    directoryName(outputRoot),
    directoryName(manifestPath),
    directoryName(directoryName(manifestPath)),
    directoryName(directoryName(directoryName(manifestPath))),
  ]
    .map((candidate) => standardizeOptionalPath(candidate))
    .filter(Boolean);

  for (const candidate of candidates) {
    if (findPdfBuildHelper(candidate)) {
      return candidate;
    }
  }

  return directoryName(outputRoot);
}

function safeValue(getter) {
  try {
    return getter();
  } catch (_error) {
    return null;
  }
}

function safeNumber(getter, fallback) {
  const value = safeValue(getter);
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function safeList(getter) {
  const value = safeValue(getter);
  return Array.isArray(value) ? value : [];
}

function runProcess(argv) {
  const task = $.NSTask.alloc.init;
  task.setLaunchPath($(argv[0]));
  task.setArguments($(argv.slice(1)));

  const stdoutPipe = $.NSPipe.pipe;
  const stderrPipe = $.NSPipe.pipe;
  task.setStandardOutput(stdoutPipe);
  task.setStandardError(stderrPipe);

  task.launch;
  task.waitUntilExit;

  const stdoutText = nsDataToString(stdoutPipe.fileHandleForReading.readDataToEndOfFile);
  const stderrText = nsDataToString(stderrPipe.fileHandleForReading.readDataToEndOfFile);
  if (task.terminationStatus !== 0) {
    throw new Error(stderrText || stdoutText || `Command failed: ${argv.join(" ")}`);
  }
  return stdoutText;
}

function nsDataToString(data) {
  if (!data || data.length === 0) {
    return "";
  }
  const text = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
  return text ? ObjC.unwrap(text) : "";
}

function runSafariJavaScript(windowRef, script) {
  const safari = ensureSafari(null);
  const tab = safeValue(() => windowRef.currentTab());
  if (!tab) {
    return null;
  }
  return safeValue(() => safari.doJavaScript(script, { in: tab }));
}

function unwrapError(errorRef) {
  if (!errorRef || !errorRef[0]) {
    return "unknown error";
  }
  return ObjC.unwrap(errorRef[0].localizedDescription);
}

function ensureSafari(existingSafari) {
  if (existingSafari) {
    return existingSafari;
  }

  const safari = Application("/Applications/Safari.app");
  safari.launch();
  delay(0.5);
  return safari;
}
