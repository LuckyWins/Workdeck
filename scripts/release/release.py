#!/usr/bin/env python3
"""Release helpers for Workdeck (in-app updates spec §4–§5).

  prepare VERSION   move CHANGELOG's Unreleased under VERSION, bump the project's versions, commit
  check VERSION     the tag's version matches the project and CHANGELOG has its section (CI)
  notes VERSION     the section's notes as markdown (release body) or html (appcast)
  appcast ...       write appcast.xml with one signed item (CI)
  min-system        the app's deployment target

Standard library only; run with `python3 -I`. Never prints secrets.
"""

import argparse
import datetime
import email.utils
import html
import pathlib
import re
import subprocess
import sys
import xml.sax.saxutils as saxutils

ROOT = pathlib.Path(__file__).resolve().parents[2]
CHANGELOG = "CHANGELOG.md"
PBXPROJ = "Workdeck.xcodeproj/project.pbxproj"
SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
HEADING = re.compile(r"^## (.+?)\s*$")
VERSION_HEADING = re.compile(r"^(\S+)\s+[—–-]\s+(\S+)$")


class ReleaseError(Exception):
    pass


# Reading the project and the changelog


def _changelog(root):
    return (root / CHANGELOG).read_text(encoding="utf-8")


def _pbxproj(root):
    return (root / PBXPROJ).read_text(encoding="utf-8")


def _setting(pbx, name):
    values = set(re.findall(rf"\b{name} = ([^;]+);", pbx))
    if len(values) != 1:
        raise ReleaseError(f"{PBXPROJ}: expected one value of {name}, found {sorted(values) or 'none'}")
    return values.pop().strip().strip('"')


def marketing_version(root):
    return _setting(_pbxproj(root), "MARKETING_VERSION")


def build_number(root):
    value = _setting(_pbxproj(root), "CURRENT_PROJECT_VERSION")
    if not value.isdigit():
        raise ReleaseError(f"CURRENT_PROJECT_VERSION is not an integer: {value}")
    return int(value)


def minimum_system(root):
    return _setting(_pbxproj(root), "MACOSX_DEPLOYMENT_TARGET")


def _parse_semver(version):
    match = SEMVER.match(version)
    if not match:
        raise ReleaseError(f"not a version like 1.2.3: {version}")
    return tuple(int(part) for part in match.groups())


def _version_tuple(text):
    parts = [int(p) for p in re.findall(r"\d+", text)]
    return tuple((parts + [0, 0, 0])[:3])


def _sections(text):
    """[(heading, start_line, end_line)] for every `## ` section, end exclusive."""
    lines = text.split("\n")
    starts = [i for i, line in enumerate(lines) if HEADING.match(line)]
    return lines, [(HEADING.match(lines[s]).group(1), s, (starts[n + 1] if n + 1 < len(starts) else len(lines)))
                   for n, s in enumerate(starts)]


def _section_body(text, version):
    lines, sections = _sections(text)
    for heading, start, end in sections:
        match = VERSION_HEADING.match(heading)
        number = match.group(1) if match else heading
        if number == version:
            return "\n".join(lines[start + 1:end]).strip()
    raise ReleaseError(f"{CHANGELOG} has no section for {version}")


# prepare


def _git(root, *args, identity=None):
    prefix = []
    if identity:
        prefix = ["-c", f"user.name={identity[0]}", "-c", f"user.email={identity[1]}"]
    return subprocess.run(["git", *prefix, *args], cwd=root, check=True, capture_output=True, text=True).stdout


def prepare(root, version, today=None, commit=True, git_identity=None):
    root = pathlib.Path(root)
    new = _parse_semver(version)
    if _git(root, "status", "--porcelain").strip():
        raise ReleaseError("the working tree has changes; commit or stash them first")
    current = marketing_version(root)
    if new <= _version_tuple(current):
        raise ReleaseError(f"{version} is not above the current version {current}")
    text = _changelog(root)
    lines, sections = _sections(text)
    unreleased = next(((s, e) for heading, s, e in sections if heading.strip() == "Unreleased"), None)
    if unreleased is None:
        raise ReleaseError(f"{CHANGELOG} has no '## Unreleased' section")
    start, end = unreleased
    if not any(line.startswith("- ") for line in lines[start + 1:end]):
        raise ReleaseError(f"'## Unreleased' in {CHANGELOG} has no lines")
    date = today or datetime.date.today().isoformat()
    body = lines[start + 1:end]
    while body and not body[-1].strip():
        body.pop()
    while body and not body[0].strip():
        body.pop(0)
    new_lines = lines[:start] + ["## Unreleased", "", f"## {version} — {date}", ""] + body + [""] + lines[end:]
    new_text = "\n".join(new_lines)

    pbx = _pbxproj(root)
    build = build_number(root) + 1
    pbx = re.sub(r"\bMARKETING_VERSION = [^;]+;", f"MARKETING_VERSION = {version};", pbx)
    pbx = re.sub(r"\bCURRENT_PROJECT_VERSION = [^;]+;", f"CURRENT_PROJECT_VERSION = {build};", pbx)

    (root / CHANGELOG).write_text(new_text, encoding="utf-8")
    (root / PBXPROJ).write_text(pbx, encoding="utf-8")
    if commit:
        _git(root, "add", CHANGELOG, PBXPROJ)
        _git(root, "commit", "-q", "-m", f"chore: release {version}", identity=git_identity)
    return build


# check and notes


def check(root, version):
    root = pathlib.Path(root)
    _parse_semver(version)
    current = marketing_version(root)
    if current != version:
        raise ReleaseError(f"the tag says {version} but MARKETING_VERSION is {current}")
    _section_body(_changelog(root), version)


def notes(root, version, fmt):
    body = _section_body(_changelog(pathlib.Path(root)), version)
    if fmt == "markdown":
        return body
    if fmt != "html":
        raise ReleaseError(f"unknown format {fmt}")
    out, items = [], []

    def flush():
        if items:
            out.append("<ul>" + "".join(f"<li>{html.escape(item, quote=False)}</li>" for item in items) + "</ul>")
            items.clear()

    for line in body.split("\n"):
        line = line.strip()
        if line.startswith("### "):
            flush()
            out.append(f"<h3>{html.escape(line[4:].strip(), quote=False)}</h3>")
        elif line.startswith("- "):
            items.append(line[2:].strip())
    flush()
    return "".join(out)


# appcast


def appcast(version, build, url, length, signature, min_system, notes_file, out):
    description = pathlib.Path(notes_file).read_text(encoding="utf-8").replace("]]>", "]]&gt;")
    q = saxutils.quoteattr
    e = saxutils.escape
    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Workdeck</title>
    <item>
      <title>{e(f"Version {version}")}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{e(str(build))}</sparkle:version>
      <sparkle:shortVersionString>{e(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{e(min_system)}</sparkle:minimumSystemVersion>
      <description><![CDATA[{description}]]></description>
      <enclosure url={q(url)} length={q(str(length))} type="application/octet-stream" sparkle:edSignature={q(signature)} />
    </item>
  </channel>
</rss>
"""
    pathlib.Path(out).write_text(xml, encoding="utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("version")
    p.add_argument("--root", default=ROOT, type=pathlib.Path)
    p.add_argument("--today")
    p.add_argument("--no-commit", action="store_true")
    c = sub.add_parser("check")
    c.add_argument("version")
    c.add_argument("--root", default=ROOT, type=pathlib.Path)
    n = sub.add_parser("notes")
    n.add_argument("version")
    n.add_argument("--format", choices=["markdown", "html"], required=True)
    n.add_argument("--root", default=ROOT, type=pathlib.Path)
    m = sub.add_parser("min-system")
    m.add_argument("--root", default=ROOT, type=pathlib.Path)
    a = sub.add_parser("appcast")
    a.add_argument("--version", required=True)
    a.add_argument("--build", required=True, type=int)
    a.add_argument("--url", required=True)
    a.add_argument("--length", required=True, type=int)
    a.add_argument("--signature", required=True)
    a.add_argument("--min-system", required=True)
    a.add_argument("--notes-file", required=True, type=pathlib.Path)
    a.add_argument("--out", required=True, type=pathlib.Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            build = prepare(args.root, args.version, today=args.today, commit=not args.no_commit)
            print(f"Prepared {args.version} (build {build}). Push main, then: git tag v{args.version} && git push origin v{args.version}")
        elif args.command == "check":
            check(args.root, args.version)
            print(f"{args.version} matches the project and the changelog")
        elif args.command == "notes":
            print(notes(args.root, args.version, args.format))
        elif args.command == "min-system":
            print(minimum_system(args.root))
        elif args.command == "appcast":
            appcast(args.version, args.build, args.url, args.length, args.signature, args.min_system,
                    args.notes_file, args.out)
    except ReleaseError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as error:
        print(f"error: git failed: {error.stderr.strip()}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
