"""tests/tui/fixtures.py — shared porcelain fixture text for the TUI suites.

Fixture rows are the §2.6 golden shapes from
docs/architecture/tui-offload-manager-diff.md. No test invokes the real
provision script or touches the real $HOME — the executor env is always
injected and fake scripts emit these fixtures.
"""

HEADER = "porcelain=1"

# --classify --porcelain: exactly 15 rows (8 xdg + 3 code + 4 local),
# registry order. git field always empty from classify.
CLASSIFY_FIXTURE = """porcelain=1
xdg|desktop|Desktop|localdir||
xdg|documents|Documents|symlink|/sandbox/cloud/documents|
xdg|downloads|Downloads|localdir||
xdg|music|Music|localdir||
xdg|pictures|Pictures|symlink|/sandbox/cloud/pictures|
xdg|videos|Videos|absent||
xdg|public|Public|absent||
xdg|templates|Templates|absent||
code|repos|repos|localdir||
code|androidstudio|AndroidStudioProjects|absent||
code|projects|Projects|symlink|/sandbox/cloud/Projects|
local|pyenv|pyenv|localdir||
local|applications|Applications|localdir||
local|syslog|log|absent||
local|qemu|QEMU|localdir||
"""

# --offload-status --porcelain: exactly 3 rows (CODE_KEYS order).
# repos is deliberately offloaded while classify says localdir above —
# the join must derive 'inconsistent' (TUI-derived, §4.2).
STATUS_FIXTURE = """porcelain=1
code|repos|repos|offloaded|gdrive:xdg-offload/code/repos|
code|androidstudio|AndroidStudioProjects|absent||none
code|projects|Projects|local||clean
"""

# §2.6 golden lines, one per reachable enum state, verbatim.
GOLDEN_CLASSIFY_LINES = [
    "xdg|documents|Documents|symlink|/sandbox/cloud/documents|",
    "xdg|music|Music|localdir||",
    "xdg|templates|Templates|absent||",
    "code|projects|Projects|symlink|/sandbox/cloud/Projects|",
    "code|repos|repos|localdir||",
    "local|pyenv|pyenv|localdir||",
]

GOLDEN_STATUS_LINES = [
    "code|repos|repos|offloaded|gdrive:xdg-offload/code/repos|",
    "code|repos|repos|offloaded|<unknown remote>|",
    "code|repos|repos|local||clean",
    "code|repos|repos|local||dirty",
    "code|repos|repos|local||none",
    "code|androidstudio|AndroidStudioProjects|absent||none",
]
