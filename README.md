# Droidian Package Builder

Droidian package projects are configured in `projects.json`. A project can have two build variants:

- `base`: applies the normal patch/script layer and publishes to APT suite `main`, component `main`.
- `additional`: applies the base layer plus the additional patch/script layer and publishes to APT suite `additional`, component `main`.

The `base` and `additional` booleans control automatic selection only. A variant can still be requested manually or selected as a dependency while its automatic flag is `false`.

## Repository layout

```text
.github/workflows/
├── build.yml
└── publish.yml

patches/
└── <project>/
    └── 0001-description.patch

patches-additional/
└── <project>/
    └── 0001-description.patch

project-scripts/
├── before/
│   └── <project>
└── after/
    └── <project>

project-scripts-additional/
├── before/
│   └── <project>
└── after/
    └── <project>

scripts/
├── build.sh
├── build-project.sh
├── ci-plan.sh
├── local-build.sh
├── local-build-project.sh
├── prepare-bundle.sh
├── publish-apt-repo.sh
├── validate.sh
└── wait-for-dependencies.sh

projects.json
```

## Project configuration

```json
{
  "name": "application-example",
  "base": true,
  "additional": true,
  "repo": "https://github.com/example/application-example.git",
  "branch": "main",
  "apt_packages": [],
  "dependencies": [
    {
      "project": "library-example",
      "packages": ["library-example"]
    }
  ],
  "dependencies-additional": [
    {
      "project": "library-example",
      "additional": true,
      "packages": ["library-example"]
    }
  ]
}
```

### Automatic build flags

`base: true` selects the base variant during an automatic build. `additional: true` selects the additional variant during an automatic build. `additional` defaults to `false` when omitted.

These flags do not disable a variant. For example, a project with no `additional: true` can still be requested explicitly as `<project>-additional`, or be selected by a dependency with `"additional": true`.

### Dependencies

`dependencies` is the dependency set used by a base build. Dependency entries default to the base variant:

```json
{
  "project": "library-example",
  "packages": ["library-example", "library-example-dev"]
}
```

Set `additional: true` on a dependency entry to consume that project's additional build:

```json
{
  "project": "library-example",
  "additional": true,
  "packages": ["library-example"]
}
```

For an additional consumer build, `dependencies-additional` overlays `dependencies`. If the same project is present in `dependencies-additional`, that entry replaces the base dependency entry for the additional consumer. Other base dependencies are inherited unchanged.

For example:

```text
application/base
├── library/base
└── helper/base

application/additional
├── library/additional
└── helper/base
```

An empty `packages` array installs every `.deb` produced by that dependency.

## Patch layers

Base builds apply:

```text
patches/<project>/*.patch
```

Additional builds apply, in order:

```text
patches/<project>/*.patch
patches-additional/<project>/*.patch
```

Active patch names use a four-digit numeric prefix and are applied in numeric order:

```text
0001-first-change.patch
0002-second-change.patch
```

Additional patch files may remain in the repository even when `additional` automatic selection is disabled.

## Project script layers

Base builds run:

```text
project-scripts/before/<project>
BUILD
project-scripts/after/<project>
```

Additional builds run:

```text
project-scripts/before/<project>
project-scripts-additional/before/<project>
BUILD
project-scripts/after/<project>
project-scripts-additional/after/<project>
```

Each project script path is a Bash script file, not a directory. Missing scripts are allowed.

Available variables include:

```text
PROJECT_NAME
PROJECT_VARIANT
PROJECT_ADDITIONAL
PROJECT_REPO
PROJECT_BRANCH
PROJECT_SOURCE_DIR
PROJECT_BUILD_DIR
PROJECT_OUTPUT_DIR
DEB_BUILD_OPTIONS
DEBFULLNAME
DEBEMAIL
```

## CI planning

The internal build graph identifies a node by project and variant, so `libhybris` and `libhybris [additional]` are separate build nodes.

An empty workflow input selects every automatic root from `base: true` and `additional: true`, then adds its dependency closure.

Manual workflow targets use the project name for base and the `-additional` suffix for additional:

```text
libhybris
libhybris-additional
wlroots-additional
```

Multiple targets are comma-separated.

GitHub Actions displays additional jobs as:

```text
Build libhybris [additional]
```

Artifacts use:

```text
project-libhybris
project-libhybris-additional
```

## Direct builds

`scripts/build.sh` builds directly in the current environment and therefore expects the environment architecture to match the selected matrix group.

```bash
./scripts/build.sh libhybris
./scripts/build.sh --additional libhybris
```

A no-argument direct build can only proceed when the selected graph uses one build architecture.

## Local container builds

Use `local-build.sh` on the host. It selects Podman or Docker and uses the project image and `--platform`, allowing the container runtime/binfmt setup to handle cross-architecture execution.

```bash
./scripts/local-build.sh libhybris
./scripts/local-build.sh --additional wlroots
```

Dependencies are built first in their own containers and consumed from `local-output`.

Outputs are stored under:

```text
local-output/<project>/base/
local-output/<project>/additional/
```

## APT repository

The published repository has two suites, both using component `main`:

```text
deb https://droidian-marble.github.io/build-system/ additional main
deb https://droidian-marble.github.io/build-system/ main main
```

The repository layout is:

```text
dists/main/main/binary-arm64/
dists/additional/main/binary-arm64/
pool/main/
pool/additional/
```

Base build environments enable only `main main` and pin the repository origin to priority `1003`.

Additional build environments enable both suites. The `additional main` source is listed first, and suite `additional` receives priority `1004`; `main` remains at `1003`.

APT preferences select versions, not different source instances of an identical version. If base and additional publish different package contents with the same package name and Debian version, the additional source ordering makes the additional instance win inside additional build environments, but publishing distinct package versions is still the correct long-term package model.

## Publishing and failure isolation

Build artifacts are grouped by dependency-connected build components. A failed component is omitted from the publish bundle, while independent successful components can still be published.

Base and additional repository ownership state are independent. Disabling automatic selection does not remove stored repository ownership; removing a project from `projects.json` does.


