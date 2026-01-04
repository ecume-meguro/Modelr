#!/usr/bin/env python3

import argparse
import ast
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

try:
    from concurrent.futures import ThreadPoolExecutor, as_completed
except Exception:  # pragma: no cover
    ThreadPoolExecutor = None  # type: ignore
    as_completed = None  # type: ignore

try:
    import tomllib  # py3.11+
except Exception:  # pragma: no cover
    tomllib = None  # type: ignore

try:
    from urllib.request import urlopen
except Exception:  # pragma: no cover
    urlopen = None  # type: ignore


NAME_NORMALIZE_RE = re.compile(r"[-_.]+")


def norm_name(name: str) -> str:
    return NAME_NORMALIZE_RE.sub("-", name).lower().strip()


@dataclass(frozen=True)
class Dep:
    name: str
    kind: str  # pypi | direct
    ref: str | None
    source: str


def parse_req_line(line: str) -> Dep | None:
    line = line.strip()
    if not line or line.startswith("#"):
        return None
    if line.startswith(("-", "--")):
        return None

    if ";" in line:
        line = line.split(";", 1)[0].strip()

    direct = re.match(r"^([A-Za-z0-9_.-]+)\s*@\s*(.+)$", line)
    if direct:
        return Dep(name=direct.group(1), kind="direct", ref=direct.group(2).strip(), source="")

    m = re.match(
        r"^([A-Za-z0-9_.-]+)(\[.*?\])?\s*(==|>=|<=|~=|!=|>|<).*$", line
    )
    if m:
        return Dep(name=m.group(1), kind="pypi", ref=None, source="")

    m = re.match(r"^([A-Za-z0-9_.-]+)(\[.*?\])?$", line)
    if m:
        return Dep(name=m.group(1), kind="pypi", ref=None, source="")

    return None


def parse_requirements(path: Path) -> list[Dep]:
    if not path.exists():
        return []
    deps: list[Dep] = []
    for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        dep = parse_req_line(raw)
        if dep:
            deps.append(Dep(name=dep.name, kind=dep.kind, ref=dep.ref, source=str(path)))
    return deps


def parse_pyproject(path: Path) -> list[Dep]:
    if not path.exists():
        return []
    if tomllib is None:
        raise RuntimeError("tomllib unavailable; need Python 3.11+")

    data = tomllib.loads(path.read_text(encoding="utf-8", errors="ignore"))

    deps: list[Dep] = []
    for raw in (data.get("project", {}) or {}).get("dependencies", []) or []:
        dep = parse_req_line(raw)
        if dep:
            deps.append(Dep(name=dep.name, kind=dep.kind, ref=dep.ref, source=str(path)))

    overrides = (((data.get("tool", {}) or {}).get("uv", {}) or {}).get("override-dependencies", []) or [])
    for raw in overrides:
        dep = parse_req_line(raw)
        if dep:
            deps.append(Dep(name=dep.name, kind=dep.kind, ref=(dep.ref or "uv-override"), source=str(path)))

    return deps


def parse_setup_py(path: Path) -> list[Dep]:
    if not path.exists():
        return []
    text = path.read_text(encoding="utf-8", errors="ignore")
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return []

    deps: list[Dep] = []

    class Visitor(ast.NodeVisitor):
        def visit_Call(self, node: ast.Call) -> None:
            try:
                func_name = None
                if isinstance(node.func, ast.Name):
                    func_name = node.func.id
                elif isinstance(node.func, ast.Attribute):
                    func_name = node.func.attr
                if func_name != "setup":
                    return

                for kw in node.keywords or []:
                    if kw.arg != "install_requires":
                        continue
                    val = kw.value
                    if isinstance(val, (ast.List, ast.Tuple)):
                        for elt in val.elts:
                            if isinstance(elt, ast.Constant) and isinstance(elt.value, str):
                                dep = parse_req_line(elt.value)
                                if dep:
                                    deps.append(Dep(name=dep.name, kind=dep.kind, ref=dep.ref, source=str(path)))
            finally:
                self.generic_visit(node)

    Visitor().visit(tree)
    return deps


def parse_uv_lock(path: Path) -> list[Dep]:
    if not path.exists():
        return []
    if tomllib is None:
        raise RuntimeError("tomllib unavailable; need Python 3.11+")

    data = tomllib.loads(path.read_text(encoding="utf-8", errors="ignore"))
    pkgs = data.get("package") or []
    deps: list[Dep] = []
    if isinstance(pkgs, list):
        for rec in pkgs:
            if not isinstance(rec, dict):
                continue
            name = rec.get("name")
            if not isinstance(name, str) or not name.strip():
                continue

            # Only include registry packages; direct/git/file sources are handled elsewhere.
            source = rec.get("source")
            if isinstance(source, dict) and "registry" in source:
                deps.append(Dep(name=name.strip(), kind="pypi", ref=None, source=str(path)))
    return deps


def iter_deps(manifests: Iterable[Path]) -> list[Dep]:
    deps: list[Dep] = []
    for path in manifests:
        if path.name.startswith("requirements"):
            deps.extend(parse_requirements(path))
        elif path.name.startswith("pyproject"):
            deps.extend(parse_pyproject(path))
        elif path.name == "setup.py":
            deps.extend(parse_setup_py(path))
        elif path.name == "uv.lock":
            deps.extend(parse_uv_lock(path))
    return deps


def fetch_pypi_json(pkg_norm: str) -> dict:
    if urlopen is None:
        return {"error": "urllib unavailable", "url": None}
    url = f"https://pypi.org/pypi/{pkg_norm}/json"
    try:
        with urlopen(url, timeout=20) as resp:
            return json.load(resp)
    except Exception as e:
        return {"error": str(e), "url": url}


def summarize_license(pypi_json: dict) -> dict:
    if "info" not in pypi_json:
        return {"license": None, "license_classifiers": [], "home": None, "error": pypi_json.get("error"), "url": pypi_json.get("url")}

    info = pypi_json.get("info", {}) or {}
    license_raw = (info.get("license") or "").strip() or None
    classifiers = info.get("classifiers") or []
    lic_cls = [c for c in classifiers if isinstance(c, str) and c.startswith("License ::")]
    home = info.get("home_page") or None
    project_urls = info.get("project_urls") or {}
    if not home and isinstance(project_urls, dict):
        home = project_urls.get("Homepage") or project_urls.get("Source") or project_urls.get("Repository")

    # PyPI sometimes stores the full license text in info.license; for reporting,
    # keep raw but prefer a short string.
    license_short = license_raw
    if license_short and ("\n" in license_short or len(license_short) > 120):
        license_short = None

    return {
        "license": license_short,
        "license_raw": license_raw,
        "license_classifiers": lic_cls,
        "home": home,
        "url": f"https://pypi.org/project/{info.get('name')}/" if info.get("name") else None,
        "error": None,
    }


def find_local_license(start: Path) -> dict:
    """Best-effort detection of local LICENSE for vendored repos/direct deps."""
    cur = start
    for _ in range(6):
        if not cur.exists():
            break
        for name in ("LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING", "COPYING.txt"):
            cand = cur / name
            if cand.exists() and cand.is_file():
                head = cand.read_text(encoding="utf-8", errors="ignore")[:400]
                first_line = head.splitlines()[0].strip() if head else ""
                return {
                    "path": str(cand),
                    "first_line": first_line or None,
                }
        if cur.parent == cur:
            break
        cur = cur.parent
    return {"path": None, "first_line": None}


def load_cache(cache_path: Path) -> dict:
    try:
        return json.loads(cache_path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_cache(cache_path: Path, cache: dict) -> None:
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(json.dumps(cache, indent=2, sort_keys=True), encoding="utf-8")


def resolve_pypi_licenses(keys: list[str], cache_path: Path, max_workers: int = 16) -> dict[str, dict]:
    cache = load_cache(cache_path)
    out: dict[str, dict] = {}

    todo = [k for k in keys if k not in cache]
    if todo and ThreadPoolExecutor is not None:
        workers = max(1, min(max_workers, 32))
        with ThreadPoolExecutor(max_workers=workers) as ex:
            futs = {ex.submit(fetch_pypi_json, k): k for k in todo}
            for fut in as_completed(futs):
                k = futs[fut]
                try:
                    cache[k] = summarize_license(fut.result())
                except Exception as e:
                    cache[k] = {"license": None, "license_classifiers": [], "home": None, "url": None, "error": str(e)}

        save_cache(cache_path, cache)
    elif todo:
        for k in todo:
            cache[k] = summarize_license(fetch_pypi_json(k))
        save_cache(cache_path, cache)

    for k in keys:
        out[k] = cache.get(k) or {"license": None, "license_classifiers": [], "home": None, "url": None, "error": "cache-miss"}
    return out


def discover_paths(root: Path, include_locks: bool) -> list[Path]:
    # Only scan known python-ish trees to avoid crawling build caches.
    bases = [
        root / "Resources",
        root / "Hunyuan3D-2",
        root / "mlx-sam3",
        root / "sam3",
        root / "sam2-studio",
    ]
    wanted: list[Path] = []
    skip_dirs = {
        ".git",
        ".venv",
        "venv",
        "__pycache__",
        "build",
        "dist",
        "node_modules",
        ".mypy_cache",
        ".pytest_cache",
    }
    for base in bases:
        if not base.exists():
            continue
        for p in base.rglob("*"):
            # prune common vendor/venv directories
            if any(part in skip_dirs for part in p.parts):
                continue
            if any(part.endswith(".egg-info") for part in p.parts):
                continue
            if not p.is_file():
                continue
            n = p.name
            if n.startswith("requirements") and n.endswith(".txt"):
                wanted.append(p)
            elif n in {"pyproject.toml", "pyproject_hunyuan.toml", "setup.py"}:
                wanted.append(p)
            elif include_locks and n == "uv.lock":
                wanted.append(p)
    # de-dupe
    return sorted({p.resolve() for p in wanted})


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--include-locks", action="store_true", help="Include uv.lock resolved dependencies (transitive)")
    ap.add_argument("--no-include-locks", action="store_true", help="Do not include uv.lock dependencies")
    ap.add_argument("--cache", default=None, help="Path to cache PyPI lookups (JSON)")
    ap.add_argument("--output", default=None, help="Write full JSON report to a file")
    args = ap.parse_args()

    root = Path(args.root).resolve()

    include_locks = bool(args.include_locks) and not bool(args.no_include_locks)
    manifests = discover_paths(root, include_locks=include_locks)
    deps = iter_deps(manifests)

    cache_path = Path(args.cache).expanduser().resolve() if args.cache else (root / ".cache" / "pypi_licenses.json")

    merged: dict[str, dict] = {}
    for dep in deps:
        key = norm_name(dep.name)
        rec = merged.setdefault(key, {"name": dep.name, "kind": dep.kind, "sources": set(), "refs": set()})
        rec["sources"].add(dep.source)
        if dep.kind == "direct" and dep.ref:
            rec["refs"].add(dep.ref)

    pypi_keys = [k for k, v in merged.items() if v.get("kind") == "pypi"]
    pypi_licenses = resolve_pypi_licenses(sorted(pypi_keys), cache_path=cache_path)

    report: dict[str, dict] = {}
    for key in sorted(merged.keys()):
        rec = merged[key]
        out = {
            "name": rec["name"],
            "kind": rec["kind"],
            "sources": sorted(rec["sources"]),
        }
        if rec["refs"]:
            out["refs"] = sorted(rec["refs"])
        if rec["kind"] == "pypi":
            out["pypi"] = pypi_licenses.get(key)
        else:
            # Best-effort license for direct deps.
            refs = sorted(rec["refs"]) if rec["refs"] else []
            resolved = None
            for r in refs:
                if r.startswith("file://"):
                    p = Path(r[len("file://"):]).expanduser()
                    resolved = find_local_license(p)
                    resolved["resolved_path"] = str(p)
                    break
                if "Hunyuan3D-2" in r and (root / "Hunyuan3D-2").exists():
                    resolved = find_local_license(root / "Hunyuan3D-2")
                    resolved["resolved_path"] = str((root / "Hunyuan3D-2").resolve())
                    break
            if resolved:
                out["direct_license"] = resolved
        report[key] = out

    local_repos = {}
    for folder in ("Hunyuan3D-2", "mlx-sam3", "sam3", "sam2-studio"):
        p = root / folder
        if p.exists():
            local_repos[folder] = find_local_license(p)

    full = {
        "root": str(root),
        "manifests": [str(p) for p in manifests],
        "local_repos": local_repos,
        "packages": report,
    }

    if args.output:
        Path(args.output).expanduser().resolve().write_text(json.dumps(full, indent=2, sort_keys=True), encoding="utf-8")

    if args.json:
        print(json.dumps(full, indent=2, sort_keys=True))
        return 0

    # pretty
    # pretty
    print(f"Manifests scanned: {len(manifests)}")
    for repo, lic in local_repos.items():
        if lic.get("path"):
            print(f"repo:{repo}: {lic.get('first_line') or 'LICENSE'}")
        else:
            print(f"repo:{repo}: (no LICENSE found)")

    for key, rec in report.items():
        if rec.get("kind") == "direct":
            dl = rec.get("direct_license") or {}
            if dl.get("path"):
                print(f"{key}: DIRECT  {dl.get('first_line') or 'LICENSE'}")
            else:
                print(f"{key}: DIRECT  refs={rec.get('refs')}")
        else:
            p = rec.get("pypi", {})
            lic = p.get("license") or ""
            cls = p.get("license_classifiers") or []
            cls_short = (cls[0] if cls else "")
            err = p.get("error")
            if err:
                print(f"{key}: UNKNOWN (PyPI lookup failed: {err})")
            else:
                print(f"{key}: {lic or cls_short or 'UNKNOWN'}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
