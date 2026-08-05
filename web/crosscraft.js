function downloadFileFromVirtualFs(files, path, normalizePath) {
  const name = normalizePath(path);
  const data = files.get(name);
  if (!data) {
    console.warn(`CrossCraft download requested missing file: ${name}`);
    return false;
  }

  const parts = name.split("/");
  const filename = parts[parts.length - 1] || "world.cw";
  const blob = new Blob([data], { type: "application/octet-stream" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  link.style.display = "none";
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 0);
  return true;
}

export function hostImports({ files, normalizePath, str }) {
  return {
    aether_crosscraft_download_file(pathPtr, pathLen) {
      return downloadFileFromVirtualFs(
        files,
        str(pathPtr, pathLen),
        normalizePath,
      );
    },
  };
}
