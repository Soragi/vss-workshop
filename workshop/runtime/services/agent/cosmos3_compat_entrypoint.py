#!/usr/local/bin/python3
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Apply the VSS 3.2.1 Cosmos 3 request-shape fix, then start VSS Agent.

VSS Agent 3.2.1 recognizes Cosmos 3, but sends its pixel budget using the
legacy ``videos_kwargs`` schema. Cosmos 3 Reasoner expects ``size`` with
``shortest_edge`` and ``longest_edge`` instead. Keep this compatibility shim
small, exact, and fail-closed so a future image change cannot be patched
silently.
"""

from __future__ import annotations

import os
from pathlib import Path
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


def patch_cosmos3_request_shape() -> None:
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
    if PATCHED in source:
        return
    if source.count(ORIGINAL) != 1:
        raise RuntimeError(
            "The installed VSS Agent no longer matches the validated 3.2.1 "
            "Cosmos compatibility patch."
        )

    module_path.write_text(source.replace(ORIGINAL, PATCHED, 1), encoding="utf-8")
    print("Applied VSS 3.2.1 Cosmos 3 preprocessing compatibility fix.", flush=True)


def main() -> None:
    patch_cosmos3_request_shape()
    os.execv(
        sys.executable,
        [sys.executable, "/vss-agent/entrypoint.py", *sys.argv[1:]],
    )


if __name__ == "__main__":
    main()
