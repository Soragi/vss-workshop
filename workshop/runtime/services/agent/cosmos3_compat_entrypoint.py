#!/usr/local/bin/python3
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Apply the VSS 3.2.1 Cosmos 3 request-shape fix, then start VSS Agent.

VSS Agent 3.2.1 recognizes Cosmos 3, but sends its pixel budget using the
legacy ``videos_kwargs`` schema. Cosmos 3 Reasoner expects ``size`` with
``shortest_edge`` and ``longest_edge`` instead. Keep this compatibility shim
small, exact, and fail-closed so a future image change cannot be patched
silently. Run the NAT console script in this interpreter because the stock
entrypoint uses ``execv``, which would discard the in-memory import hook.
"""

from __future__ import annotations

import importlib.abc
import importlib.util
import os
from pathlib import Path
import runpy
import sys


ORIGINAL = """            if is_cosmos_reason2:
                mm_processor_kwargs = {"size": {"shortest_edge": config.min_pixels, "longest_edge": config.max_pixels}}
            else:
                mm_processor_kwargs = {
                    "videos_kwargs": {"min_pixels": config.min_pixels, "max_pixels": config.max_pixels}
                }
"""

PATCHED = """            mm_processor_kwargs = {
                "size": {"shortest_edge": config.min_pixels, "longest_edge": config.max_pixels}
            }
"""

ORIGINAL_VIDEO_URL = """            video_url = rewrite_to_internal_vst_url(video_url, config.vst_internal_url)
"""

PATCHED_VIDEO_URL = """            analysis_base_url = config.vst_internal_url
            if analysis_base_url:
                analysis_base_url = f"{analysis_base_url.rsplit(':', 1)[0]}:30900"
            video_url = rewrite_to_internal_vst_url(video_url, analysis_base_url)
"""


TARGET_MODULE = "vss_agents.tools.video_understanding"
NAT_BIN = "/vss-agent/.venv/bin/nat"
_TRUTHY = {"1", "true", "yes", "on"}


class PatchedModuleLoader(importlib.abc.Loader):
    def __init__(self, module_path: Path, source: str) -> None:
        self.module_path = module_path
        self.source = source

    def create_module(self, spec):  # noqa: ANN001, ANN201
        return None

    def exec_module(self, module) -> None:  # noqa: ANN001
        code = compile(self.source, str(self.module_path), "exec")
        exec(code, module.__dict__)


class PatchedModuleFinder(importlib.abc.MetaPathFinder):
    def __init__(self, module_path: Path, source: str) -> None:
        self.module_path = module_path
        self.loader = PatchedModuleLoader(module_path, source)

    def find_spec(self, fullname, path, target=None):  # noqa: ANN001, ANN201, ARG002
        if fullname != TARGET_MODULE:
            return None
        return importlib.util.spec_from_file_location(
            fullname,
            self.module_path,
            loader=self.loader,
        )


def install_cosmos3_request_shape_fix() -> None:
    candidates = list(
        Path("/vss-agent/.venv/lib").glob(
            "python*/site-packages/vss_agents/tools/video_understanding.py"
        )
    )
    if len(candidates) != 1:
        raise RuntimeError(
            "Expected exactly one installed VSS video_understanding module; "
            f"found {len(candidates)}."
        )

    module_path = candidates[0]
    source = module_path.read_text(encoding="utf-8")
    patched_source = replace_exactly_once(source, ORIGINAL, PATCHED, "pixel-budget schema")
    patched_source = replace_exactly_once(
        patched_source,
        ORIGINAL_VIDEO_URL,
        PATCHED_VIDEO_URL,
        "analysis proxy URL",
    )

    # The NVIDIA image runs as UID 1000 and its site-packages are read-only.
    # Patch only the in-memory source used for this exact module import.
    sys.meta_path.insert(0, PatchedModuleFinder(module_path, patched_source))
    print("Applied VSS 3.2.1 Cosmos 3 preprocessing compatibility fix.", flush=True)


def replace_exactly_once(source: str, original: str, replacement: str, label: str) -> str:
    if replacement in source:
        return source
    if source.count(original) != 1:
        raise RuntimeError(
            "The installed VSS Agent no longer matches the validated 3.2.1 "
            f"Cosmos compatibility patch ({label})."
        )
    return source.replace(original, replacement, 1)


def install_proprietary_codecs_if_requested() -> None:
    value = os.environ.get("INSTALL_PROPRIETARY_CODECS", "")
    if value.strip().lower() not in _TRUTHY:
        return

    sys.path.insert(0, "/vss-agent")
    import install_proprietary_codecs  # noqa: PLC0415

    target = install_proprietary_codecs.install()
    if target:
        sys.path.insert(0, target)
        existing = os.environ.get("PYTHONPATH", "")
        os.environ["PYTHONPATH"] = target + (os.pathsep + existing if existing else "")


def main() -> None:
    install_proprietary_codecs_if_requested()
    install_cosmos3_request_shape_fix()
    sys.argv = [NAT_BIN, *sys.argv[1:]]
    runpy.run_path(NAT_BIN, run_name="__main__")


if __name__ == "__main__":
    main()
