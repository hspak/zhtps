#!/usr/bin/env python3
"""Regenerate the Linux x86-64 OpenSSL build inputs from an upstream release."""

import argparse
from collections import defaultdict
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile


CONFIGURE = (
    "linux-x86_64",
    "no-shared",
    "no-module",
    "no-engine",
    "no-dso",
    "no-legacy",
    "no-apps",
    "no-tests",
    "no-docs",
    "--prefix=/usr",
    "--openssldir=/etc/ssl",
    "--libdir=lib",
    "CC=cc",
)


def generate(source, output):
    # Configure and Make write into the source tree. Work on a private copy so
    # the pinned Zig package stays immutable and no old build products leak in.
    if (source / "configdata.pm").exists():
        raise ValueError("use a clean, unconfigured OpenSSL release directory")
    with tempfile.TemporaryDirectory(prefix="zhtps-openssl-") as temporary:
        work = Path(temporary) / "source"
        shutil.copytree(source, work)
        env = os.environ.copy()
        for name in ("CC", "CFLAGS", "CPPFLAGS", "LDFLAGS", "AR", "RANLIB"):
            env.pop(name, None)
        env["SOURCE_DATE_EPOCH"] = "0"
        env["LC_ALL"] = "C"

        def run(*args):
            try:
                return subprocess.check_output(
                    args, cwd=work, env=env, text=True, stderr=subprocess.STDOUT,
                )
            except subprocess.CalledProcessError as error:
                print(error.output)
                raise

        run("perl", "Configure", *CONFIGURE)
        run("make", "-j4", "build_generated")
        unified = json.loads(run(
            "perl", "-I.", "-Mconfigdata", "-MJSON::PP", "-e",
            "print JSON::PP->new->canonical->encode(\\%unified_info)",
        ))
        objects = set()
        visited = set()

        def visit(library):
            if library in visited:
                return
            visited.add(library)
            for child in unified["sources"][library]:
                if child.endswith(".o"):
                    objects.add(child)
                else:
                    visit(child)
            for dependency in unified["depends"].get(library, ()):
                if dependency in unified["libraries"]:
                    visit(dependency)

        visit("libssl")
        visit("libcrypto")
        generated_sources = {
            name
            for obj in objects
            for name in unified["sources"][obj]
            if name in unified["generate"]
        }
        generated_headers = {
            name for name in unified["generate"]
            if name.endswith(".h")
            and name.startswith(("include/", "crypto/", "providers/"))
            and name != "crypto/buildinf.h"
        }
        run("make", "-j4", *sorted(generated_sources | generated_headers))
        commands = run("make", "-n", "build_libs").replace("\\\n", " ")
        groups = defaultdict(lambda: {"upstream": [], "generated": []})
        compiled = set()
        for line in commands.splitlines():
            if not line.startswith("cc "):
                continue
            args = shlex.split(line)
            if "-c" not in args or "-o" not in args:
                continue
            obj = args[args.index("-o") + 1]
            if obj not in objects:
                continue
            compiled.add(obj)
            name = args[-1]
            if unified["sources"][obj] != [name]:
                raise ValueError(f"unexpected source mapping for {obj}: {args}")
            includes = tuple(arg[2:] for arg in args if arg.startswith("-I"))
            # Zig supplies target, optimization, PIC and assertion policy.
            # Retain upstream's per-object assembly and provider definitions.
            flags = tuple(arg for arg in args if arg.startswith("-D") and arg != "-DNDEBUG")
            origin = "generated" if name in generated_sources else "upstream"
            groups[(includes, flags)][origin].append(name)
        if compiled != objects:
            raise ValueError(f"missing compile recipes: {sorted(objects - compiled)}")

        # buildinf.h is created by build/openssl.zig with the actual Zig build
        # metadata, rather than the compiler and flags used for regeneration.
        generated = Path(temporary) / "generated"
        generated.mkdir()
        for name in sorted(generated_sources | generated_headers):
            destination = generated / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(work / name, destination)

        # Zig 0.16's native ELF linker does not wrap legacy .init fragments
        # with the CRT prologue/epilogue. Register the same CPU initializer in
        # .init_array so both native and LLD consumers run it before main.
        cpuid = generated / "crypto/x86_64cpuid.s"
        assembly = cpuid.read_text()
        initializer = ".section\t.init\n\tcall\tOPENSSL_cpuid_setup\n"
        if assembly.count(initializer) != 1:
            raise ValueError("upstream CPU initialization changed; review the .init_array adaptation")
        cpuid.write_text(
            "# Modified by ZHTPS: register CPU initialization through .init_array\n"
            "# for Zig's native ELF linker. The initializer itself is unchanged.\n"
            + assembly.replace(
                initializer,
                '.section\t.init_array,"aw",@init_array\n.p2align\t3\n.quad\tOPENSSL_cpuid_setup\n',
            )
        )

        version = dict(
            line.split("=", 1)
            for line in (work / "VERSION.dat").read_text().splitlines()
            if "=" in line and not line.startswith("#")
        )
        release = ".".join(version[key] for key in ("MAJOR", "MINOR", "PATCH"))
        lines = [
            "// Generated by regenerate.py from OpenSSL's configured library build.",
            ".{",
            f"    .version = {json.dumps(release)},",
            f"    .version_file = {json.dumps((work / 'VERSION.dat').read_text())},",
            "    .groups = .{",
        ]
        for (includes, flags), files in sorted(groups.items()):
            lines.append("        .{")
            for key, items in (("includes", includes), ("flags", flags),
                               ("upstream", sorted(files["upstream"])),
                               ("generated", sorted(files["generated"]))):
                lines.append(f"            .{key} = .{{")
                lines.extend(f"                {json.dumps(item)}," for item in items)
                lines.append("            },")
            lines.append("        },")
        lines += ["    },", "}", ""]
        manifest = Path(temporary) / "sources.zon"
        manifest.write_text("\n".join(lines))
        subprocess.run(["zig", "fmt", str(manifest)], check=True, stdout=subprocess.DEVNULL)
        output.mkdir(parents=True, exist_ok=True)
        if (output / "generated").exists():
            shutil.rmtree(output / "generated")
        shutil.copytree(generated, output / "generated")
        shutil.copyfile(manifest, output / "sources.zon")
        print(f"OpenSSL {release}: {len(objects)} objects, "
              f"{len(generated_sources)} generated sources, {len(generated_headers)} headers")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="clean extracted upstream release")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent)
    arguments = parser.parse_args()
    generate(arguments.source.resolve(), arguments.output.resolve())
