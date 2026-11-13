#!/usr/bin/env bats
# Exercise the Python 3.14-style dataclasses -> inspect chain on every Python.

setup() {
  load helpers
  quartet_setup
}

@test "inspect bootstrap keeps its filename from shadowing stdlib inspect" {
  run "${INSPECT_TEST_PYTHON:-python3}" - "$QUARTET_ROOT/skills/shipyard/inspect.py" <<'PY'
import builtins
import sys

source = sys.argv[1]
# Direct file execution puts its directory first, even when PYTHONPATH exists.
sys.path[0] = source.rpartition('/')[0]
original_import = builtins.__import__
triggered = False

def import_with_dataclass_chain(name, *args, **kwargs):
    global triggered
    if name == 'argparse' and not triggered:
        triggered = True
        dataclasses = original_import('dataclasses')
        dataclasses.dataclass(type('ImportProbe', (), {'__annotations__': {'value': int}}))
    return original_import(name, *args, **kwargs)

builtins.__import__ = import_with_dataclass_chain
sys.argv = [source, '--help']
namespace = {'__name__': '__main__', '__package__': None, '__file__': source}
exec(compile(open(source, encoding='utf-8').read(), source, 'exec'), namespace)
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: shipyard inspect"* ]]
}

@test "inspect executable starts with the selected Python interpreter" {
  run "${INSPECT_TEST_PYTHON:-python3}" "$QUARTET_ROOT/skills/shipyard/inspect.py" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: shipyard inspect"* ]]
}

@test "inspect executable starts through file and installed-directory symlinks" {
  ln -s "$QUARTET_ROOT/skills/shipyard/inspect.py" "$BATS_TEST_TMPDIR/inspect-link.py"
  ln -s "$QUARTET_ROOT/skills/shipyard" "$BATS_TEST_TMPDIR/installed-skill"
  for source in "$BATS_TEST_TMPDIR/inspect-link.py" "$BATS_TEST_TMPDIR/installed-skill/inspect.py"; do
    run "${INSPECT_TEST_PYTHON:-python3}" "$source" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"usage: shipyard inspect"* ]]
  done
}
