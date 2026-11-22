#!/usr/bin/env python3
"""Generates THIRD_PARTY_NOTICES.md from the production dependencies in node_modules.

Run from web/:  npm run notices
"""
import json, os, subprocess, sys

web = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
root = os.path.dirname(web)
paths = subprocess.run(["npm", "ls", "--omit=dev", "--all", "--parseable"], cwd=web,
                       capture_output=True, text=True).stdout.split("\n")
packages = {}
for path in paths:
    manifest = os.path.join(path, "package.json")
    if not path or path == web or not os.path.exists(manifest):
        continue
    meta = json.load(open(manifest))
    name, version = meta.get("name"), meta.get("version", "")
    if not name or name in packages:
        continue
    license_id = meta.get("license") or ", ".join(
        l.get("type", "") for l in meta.get("licenses", []) if isinstance(l, dict)) or "UNKNOWN"
    if isinstance(license_id, dict):
        license_id = license_id.get("type", "UNKNOWN")
    text = ""
    for f in sorted(os.listdir(path)):
        if f.lower().split(".")[0] in ("license", "licence", "copying", "notice"):
            try:
                text += open(os.path.join(path, f), encoding="utf-8", errors="replace").read().strip() + "\n\n"
            except IsADirectoryError:
                pass
    repo = meta.get("repository")
    if isinstance(repo, dict):
        repo = repo.get("url", "")
    packages[name] = (version, license_id, (repo or meta.get("homepage") or ""), text.strip())

# Packages whose metadata is incomplete or offers a choice.
OVERRIDE = {
    "khroma": "MIT",
    "elkjs": "EPL-2.0 (chosen from: EPL-2.0 OR GPL-3.0-or-later)",
}
MIT_TEXT = """Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the
following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial
portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
THE USE OR OTHER DEALINGS IN THE SOFTWARE."""
FALLBACK_TEXT = {
    "punycode.js": "Copyright Mathias Bynens <https://mathiasbynens.be/>\n\n" + MIT_TEXT,
}
for name, (v, lic, repo, text) in list(packages.items()):
    packages[name] = (v, OVERRIDE.get(name, lic), repo, text or FALLBACK_TEXT.get(name, ""))

out = ["# Third-Party Notices", "",
       "Sumi includes the following open-source software. Each component is the property of its",
       "authors and is used under the license shown.", "",
       "## Color themes", "",
       "The editor themes use color palettes from these projects:", "",
       "- Solarized — Copyright (c) Ethan Schoonover — MIT License — https://ethanschoonover.com/solarized/",
       "- Nord — Copyright (c) Sven Greb and contributors — MIT License — https://www.nordtheme.com/",
       "- Gruvbox — Copyright (c) Pavel Pertsev — MIT/X11 License — https://github.com/morhetz/gruvbox",
       "", "## Fonts", "",
       "The math fonts bundled with KaTeX are licensed under the SIL Open Font License 1.1.", "",
       "## Bundled JavaScript libraries", "",
       "| Package | Version | License |", "| --- | --- | --- |"]
for name in sorted(packages):
    v, lic, _, _ = packages[name]
    out.append(f"| {name} | {v} | {lic} |")
out.append("")
missing = []
for name in sorted(packages):
    v, lic, repo, text = packages[name]
    out += [f"### {name} {v}", "", f"License: {lic}" + (f"  \n{repo}" if repo else ""), ""]
    if text:
        out += ["```", text.replace("```", "'''"), "```", ""]
    else:
        missing.append(name)
        out += ["(No license file is shipped in the package; see the project page for the full text.)", ""]
body = "\n".join(out) + "\n"
open(os.path.join(root, "THIRD_PARTY_NOTICES.md"), "w").write(body)
open(os.path.join(root, "Sumi", "Resources", "editor", "THIRD_PARTY_NOTICES.txt"), "w").write(body)
print(f"{len(packages)} packages; without a license file: {', '.join(missing) or 'none'}")
unknown = [n for n in packages if packages[n][1] == "UNKNOWN"]
if unknown:
    print("UNKNOWN license:", ", ".join(unknown))
