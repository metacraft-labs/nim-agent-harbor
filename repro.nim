## Reprobuild project file for nim-agent-harbor.
##
## **Typed-Cross-Project-Deps rollout — the first genuine Nim-library
## CONSUMER (SC-11 develop-mode from-source sibling consumption).** Unlike
## the Wave-0 leaves (nim-acp / nim-termctl / nim-pty / nim-libvterm /
## nim-stackable-hooks / nim-everywhere), this repo is NOT a leaf: its
## ``src/`` imports a sibling workspace Nim library at build time —
## ``src/nim_agent_harbor/client.nim`` and ``.../fake.nim`` both
## ``import nim_everywhere`` (the umbrella at ``../nim-everywhere/src/
## nim_everywhere.nim``). The repo's own ``Justfile`` resolves that import
## with a hand-maintained ``paths := "--path:src --path:../nim-everywhere/src"``
## (``Justfile:4``) threaded onto every ``nim c``. This recipe expresses
## that sibling dependency the reprobuild-native way instead:
##
##   * ``uses: "nim-everywhere"`` names the sibling PRODUCER project by its
##     workspace directory name (the selector ``findSiblingProjectFile``
##     resolves to ``../nim-everywhere/repro.nim``). The producer declares
##     ``library nim_everywhere`` (``nim-everywhere/repro.nim:167``) with no
##     ``exportedPath`` (convention default ``"src"``), so the SC-11 Nim
##     library-source channel (Cross-Repo-Source-Consumption.md §4.2a)
##     builds the sibling from source and threads its ``src/`` onto THIS
##     repo's ``nim c --path:`` via the ``nimPathDirs`` aux channel — no
##     hardcoded ``../nim-everywhere/src``, no direnv, no Justfile ``--path:``.
##     Editing the sibling's ``src/`` invalidates+rebuilds this repo's test
##     compiles (the reused SC-4 fold, §4.2a.5).
##
## nim-everywhere is in the rollout's AVAILABLE set (it ships a landed
## ``repro.nim`` with ``library nim_everywhere``), so this is a proper
## ``uses: "<sibling>"`` develop-mode consumption per SC-11 — NOT a SKIP and
## NOT a hardcoded path.
##
## A Mode 1 / Mode 3 hybrid (per
## ``reprobuild-specs/Three-Mode-Convention-System.md``) modelled on the
## canonical ``runquota/repro.nim`` / ``nim-acp/repro.nim`` recipes:
##
## * Declares the toolchain floor via ``uses:`` (``nim`` + ``gcc``) plus the
##   sibling ``uses: "nim-everywhere"`` edge. Mirrors the nimble file's
##   ``requires "nim >= 2.0.0"``.
## * Declares ``library nim_agent_harbor`` so downstream consumers can
##   express a workspace dependency on this repo. The importable umbrella is
##   ``src/nim_agent_harbor.nim``; the submodules under
##   ``src/nim_agent_harbor/`` (``client``, ``fake``, ``types``) are
##   importable too.
## * Emits, per test file under ``tests/``, a BUILD edge
##   (``buildNimUnittest.build``) that compiles ``build/test-bin/<stem>`` and
##   an EXECUTE edge (``edge.testBinary.run``) that runs it — the two-edge
##   test template from ``reprobuild-specs/Package-Model.md`` §"The test
##   template", exactly as reprobuild's own ``repro.nim`` does it. The BUILD
##   halves collect into ``test-builds`` and the EXECUTE halves into ``test``
##   so ``repro build test`` / ``repro test`` materialise the runnable
##   closure.
##
## **``paths = @["src"]``.** The repo ships no ``config.nims`` / ``nim.cfg``;
## its ``Justfile`` supplies ``--path:src`` explicitly on every ``nim c``
## line (the ``--path:../nim-everywhere/src`` half is now supplied by the
## SC-11 channel, not this slot). So every BUILD edge passes
## ``paths = @["src"]`` to reproduce the local ``--path:src``; without it
## ``import nim_agent_harbor`` does not resolve. ``src`` and the nimble file
## are ``extraInputs`` so the monitor tracks the transitively imported
## ``src/nim_agent_harbor/`` modules.
##
## **Per-test platform gating.** The single ``tests/test_agent_harbor.nim``
## imports only ``std/json``, ``std/strutils``, ``unittest``, and
## ``nim_agent_harbor`` (which pulls in the sibling ``nim_everywhere``). It
## carries NO ``{.error.}`` module guard, NO OS-only import, and NO
## ``when defined(<os>)`` head-guard — it compiles + runs to ``exit 0`` on
## this Linux host under the default native backend, exactly what the repo's
## own ``just test-native`` (``nim c -r --path:src …``) runs. So there is a
## single unconditional test edge — no per-OS partition. (The repo's
## ``just test`` also runs a ``nim js`` pass via
## ``tools/nim-js-test-gate.sh``; the JS backend is a separate matrix point
## outside the two-edge native template — the native ``nim c -r`` pass is
## the baseline this corpus models, mirroring how the ``nim-everywhere``
## leaf recipe models the default-native pass and treats the JS/backend
## matrix reruns as a follow-on define/backend overlay on the same sources.)
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical recipes: the nix dev shell puts ``nim`` + ``gcc`` on ``PATH``,
## so the weak-local PATH resolver is the right default. It is also required
## for the ``uses:`` declarations to resolve at all ("typed tool
## provisioning is required for uses declarations").

import repro_project_dsl

# ``ct_test_nim_unittest`` supplies the ``buildNimUnittest.build(...)``
# typed-tool used by the test BUILD edge below, and the
# ``edge.testBinary.run(...)`` UFCS dispatch for the EXECUTE edge. It
# re-exports ``repro_project_dsl`` so the import order is unimportant.
#
# Note: like the other leaf/consumer recipes this file does NOT import
# ``ct_test_runner_install`` — that module is engine-coupled and lives at
# reprobuild's repo root, importable only from reprobuild's own project
# extraction. Without it the execute edges route through the engine's
# default direct-binary runner (run the binary, key on exit status), which
# is exactly the exit-0 verification this corpus needs; the Nim ``unittest``
# harness prints per-suite results and exits non-zero on failure.
import ct_test_nim_unittest

type
  AgentHarborTestSpec = object
    ## One entry per test file. ``source`` is the repo-relative ``.nim``
    ## path; ``binary`` is the ``build/test-bin/<stem>`` output.
    source: string
    binary: string

# The corpus — the single standalone ``tests/*.nim`` test file. It compiles
# + runs to exit 0 on every host (pure ``std/json`` + ``std/strutils`` +
# ``unittest`` + ``nim_agent_harbor``/``nim_everywhere`` — no OS gate), so
# there is one unconditional edge and no per-OS partition.
const portableTestSpecs: seq[AgentHarborTestSpec] = @[
  AgentHarborTestSpec(source: "tests/test_agent_harbor.nim",
    binary: "build/test-bin/test_agent_harbor"),
]

package nim_agent_harbor:
  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — the PATH-resolvable binaries the build needs.
    # ``nim`` compiles the test binary (the ``buildNimUnittest.build`` edge
    # below); ``gcc`` is the C back-end ``nim c`` shells out to. Mirrors the
    # nimble file's ``requires "nim >= 2.0.0"`` (the nix dev shell supplies
    # Nim 2.2.x).
    "nim >=2.0"
    "gcc >=12"

    # Sibling Nim-library producer (SC-11 develop-mode from-source
    # consumption). ``src/nim_agent_harbor/{client,fake}.nim`` ``import
    # nim_everywhere``; naming the ``nim-everywhere`` workspace project here
    # makes reprobuild build it from source (its ``library nim_everywhere``)
    # and thread its ``src/`` onto this repo's ``nim c --path:`` via the
    # ``nimPathDirs`` aux channel — replacing the ``Justfile``'s hardcoded
    # ``--path:../nim-everywhere/src``.
    "nim-everywhere"

  # Library declaration — the ``src/`` tree the ``Justfile`` puts on
  # ``--path`` is importable when this package is consumed via
  # ``uses: "nim-agent-harbor"``. The umbrella is
  # ``src/nim_agent_harbor.nim``; consumers may also import the submodules
  # under ``src/nim_agent_harbor/`` directly.
  library nim_agent_harbor

  build:
    # Two-edge test template (Package-Model.md §"The test template"): one
    # compile-only BUILD edge + one EXECUTE edge per test file. BUILD halves
    # collect into ``test-builds`` (compile-only verification); EXECUTE
    # halves collect into ``test`` so ``repro test`` / ``repro build test``
    # materialise the runnable closure (each execute edge transitively
    # depends on its build edge). ``paths = @["src"]`` reproduces the repo's
    # ``--path:src``; the sibling ``nim_everywhere`` src root is threaded
    # automatically by the SC-11 ``nimPathDirs`` channel off ``uses:
    # "nim-everywhere"``.
    var testBuildActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]

    proc emitTestPair(source, binary: string;
                      buildActions, executeActions: var seq[BuildActionDef]) =
      var lastSlash = -1
      for i in 0 ..< binary.len:
        if binary[i] == '/' or binary[i] == '\\':
          lastSlash = i
      let stem =
        if lastSlash >= 0: binary[lastSlash + 1 .. ^1]
        else: binary
      let edge = buildNimUnittest.build(
        source = source,
        binary = binary,
        paths = @["src"],
        actionId = "nim_agent_harbor.test_build." & stem,
        extraInputs = @["src", "nim_agent_harbor.nimble"])
      buildActions.add(edge.action)
      # ``registerImplicitName = false`` because the BUILD edge already owns
      # the binary basename as the implicit target name; the explicit
      # ``actionId`` is the execute edge's selector (mirrors reprobuild's
      # ``repro.nim`` two-edge shape).
      let executeEdge = edge.testBinary.run(
        actionId = "nim_agent_harbor.test_execute." & stem,
        registerImplicitName = false)
      executeActions.add(executeEdge)

    for spec in portableTestSpecs:
      emitTestPair(spec.source, spec.binary,
        testBuildActions, testExecuteActions)

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
