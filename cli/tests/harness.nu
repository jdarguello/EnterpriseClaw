# harness.nu — tiny, dependency-free helpers shared by the unit-test suites.
#
# A "suite" is a command returning a list of { name: string, run: closure } records. The closure
# performs assertions (via `std assert`) and throws on failure. run.nu executes each closure inside
# try/catch and tallies pass/fail. No external test framework (nutest etc.) is required.

# Create a unique, empty temp directory for a test and return its absolute path.
def make-tmpdir [prefix: string] {
    let base = (^mktemp -d | str trim)
    let dir = $"($base)/($prefix)"
    mkdir $dir
    $dir
}

# Seed a minimal private-repo clone (just the root kustomization.yaml) under <dir>/gitops-config,
# mirroring what kube-tools clones from the tenant repo. Returns the gitops-config path.
def seed-private-repo [dir: string, resources: list<string>] {
    let gc = $"($dir)/gitops-config"
    mkdir $gc
    { resources: $resources } | to yaml | save $"($gc)/kustomization.yaml" --force
    $gc
}
