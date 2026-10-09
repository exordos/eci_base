"""Synchronize consumers with the latest stable base image tag."""

import base64
import json
import os
import re
import subprocess
from urllib.parse import quote

import yaml


PROFILES = {"exordos_base", "exordos_base_minimal"}
UPDATE_BRANCH = "automation/update-base-image-profiles"


def api(endpoint, payload=None, paginate=False, method="PUT"):
    command = ["gh", "api", endpoint]
    if paginate:
        command += ["--paginate", "--slurp"]
    if payload is not None:
        command += ["--method", method, "--input", "-"]
    result = subprocess.run(
        command, input=json.dumps(payload) if payload is not None else None,
        text=True, capture_output=True, check=True,
    )
    return json.loads(result.stdout)


def field(node, name):
    if isinstance(node, yaml.MappingNode):
        return next((value for key, value in node.value if key.value == name), None)
    return None


def update_versions(source, version):
    """Edit only image version scalars, preserving all other YAML text."""
    root = yaml.compose(source)
    elements = field(field(root, "build"), "elements")
    edits = []
    if not isinstance(elements, yaml.SequenceNode):
        return source
    for element in elements.value:
        images = field(element, "images")
        if not isinstance(images, yaml.SequenceNode):
            continue
        for image in images.value:
            profile = field(image, "profile")
            if not isinstance(profile, yaml.ScalarNode) or profile.value not in PROFILES:
                continue
            current = field(image, "profile_version")
            if current is not None:
                if not isinstance(current, yaml.ScalarNode):
                    raise ValueError("profile_version must be a scalar")
                if current.value != version:
                    edits.append((current.start_mark.index, current.end_mark.index,
                                  json.dumps(version)))
            else:
                if image.flow_style:
                    raise ValueError("Cannot insert profile_version into a flow mapping")
                profile_key = next(key for key, _ in image.value if key.value == "profile")
                end = source.find("\n", profile.end_mark.index)
                newline = "\r\n" if "\r\n" in source else "\n"
                if end == -1:
                    edits.append((len(source), len(source), newline +
                                  " " * profile_key.start_mark.column +
                                  f"profile_version: {json.dumps(version)}" + newline))
                else:
                    edits.append((end + 1, end + 1,
                                  " " * profile_key.start_mark.column +
                                  f"profile_version: {json.dumps(version)}" + newline))
    for start, end, replacement in sorted(edits, reverse=True):
        source = source[:start] + replacement + source[end:]
    return source


def update_repository(name, branch, version):
    prefix = f"/repos/{name}"
    base = api(f"{prefix}/git/ref/heads/{quote(branch, safe='')}")["object"]["sha"]
    changes = []
    for path in ("exordos/exordos.yaml", "exordos.yaml"):
        try:
            content = api(f"{prefix}/contents/{path}?ref={base}")
        except subprocess.CalledProcessError as error:
            if "(HTTP 404)" in (error.stderr or ""):
                continue
            raise
        source = base64.b64decode(content["content"]).decode("utf-8")
        updated = update_versions(source, version)
        if updated != source:
            changes.append({"path": path, "mode": "100644",
                            "type": "blob", "content": updated})
        break  # The root manifest is a fallback when the standard path is absent.
    if not changes:
        return

    # One dedicated branch and one atomic commit for all manifests in a repository.
    base_tree = api(f"{prefix}/git/commits/{base}")["tree"]["sha"]
    new_tree = api(f"{prefix}/git/trees", {
        "base_tree": base_tree, "tree": changes,
    }, method="POST")["sha"]
    refs = api(f"{prefix}/git/matching-refs/heads/{UPDATE_BRANCH}")
    existing = next((ref for ref in refs if ref["ref"] == f"refs/heads/{UPDATE_BRANCH}"), None)
    current_tree = None
    if existing:
        current_tree = api(f"{prefix}/git/commits/{existing['object']['sha']}")["tree"]["sha"]
    if current_tree != new_tree:
        commit = api(f"{prefix}/git/commits", {
            "message": f"chore: update base image profile version to {version}",
            "tree": new_tree, "parents": [base],
        }, method="POST")["sha"]
        if existing:
            api(f"{prefix}/git/refs/heads/{UPDATE_BRANCH}",
                {"sha": commit, "force": True}, method="PATCH")
        else:
            api(f"{prefix}/git/refs", {
                "ref": f"refs/heads/{UPDATE_BRANCH}", "sha": commit,
            }, method="POST")

    pulls = api(f"{prefix}/pulls?state=open&head={quote(name.split('/')[0] + ':' + UPDATE_BRANCH, safe='')}&base={quote(branch, safe='')}")
    details = {
        "title": f"chore: update base image profiles to {version}",
        "body": f"Updates `exordos_base` and `exordos_base_minimal` image "
                f"`profile_version` values to `{version}` in {len(changes)} manifest(s).\n\n"
                "Generated by the weekly base image updater. This automation refreshes "
                "its dedicated branch from the default branch; edits on this branch "
                "may be replaced on the next run.",
    }
    if pulls:
        pull = api(f"{prefix}/pulls/{pulls[0]['number']}", details, method="PATCH")
    else:
        pull = api(f"{prefix}/pulls", {
            **details, "head": UPDATE_BRANCH, "base": branch,
        }, method="POST")
    print(f"Update PR: {pull['html_url']}", flush=True)


def main():
    if not os.environ.get("GH_TOKEN"):
        raise SystemExit("Set the EXORDOS_REPOSITORIES_TOKEN Actions secret")
    tags = subprocess.check_output(["git", "tag"], text=True).splitlines()
    stable = [tag for tag in tags if re.fullmatch(r"v?\d+\.\d+\.\d+", tag)]
    if not stable:
        raise SystemExit("No stable version tags found")
    version = max(stable, key=lambda tag: tuple(map(int, tag.lstrip("v").split("."))))
    print(f"Target base image version: {version}", flush=True)
    failures = []
    for page in api("/orgs/exordos/repos?per_page=100", paginate=True):
        for repo in page:
            if repo["archived"] or repo["disabled"] or repo["fork"] or not repo["size"]:
                continue
            name = repo["full_name"]
            branch = repo["default_branch"]
            try:
                update_repository(name, branch, version)
            except (subprocess.CalledProcessError, ValueError, yaml.YAMLError) as error:
                detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
                print(f"Failed {name}: {detail}", flush=True)
                failures.append(name)
    if failures:
        raise SystemExit(f"Failed repositories: {', '.join(failures)}")


if __name__ == "__main__":
    main()
