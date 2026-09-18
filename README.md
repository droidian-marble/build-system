# Droidian Package Builder

Droidian package projects are configured in `projects.json`.

## Repository layout

```text
.github/workflows/
├── build.yml
└── publish.yml

patches/
└── <project>/
    ├── 0001-description.patch
    └── 0002-description.patch

project-scripts/
├── before/
│   └── <project>
└── after/
    └── <project>

scripts/
├── build.sh
├── build-project.sh
├── ci-plan.sh
├── prepare-bundle.sh
├── publish-apt-repo.sh
├── validate.sh
└── wait-for-dependencies.sh

projects.json
```

## Project configuration

`projects.json` contains shared defaults and project entries.

```json
{
  "defaults": {
    "architecture": "arm64",
    "images": {
      "arm64": "quay.io/droidian/build-essential:next-arm64",
      "amd64": "quay.io/droidian/build-essential:current-amd64"
    },
    "runners": {
      "arm64": "ubuntu-24.04-arm",
      "amd64": "ubuntu-latest"
    },
    "build_command": "releng-build-package",
    "deb_build_options": "nocheck",
    "deb_fullname": "Droidian Patch Builder",
    "deb_email": "builder@localhost",
    "apt_packages": [
      "devscripts",
      "equivs",
      "dpkg-dev",
      "jq"
    ]
  },
  "projects": [
    {
      "name": "library-example",
      "enabled": true,
      "repo": "https://github.com/example/library-example.git",
      "branch": "main",
      "apt_packages": [
        "example-build-dependency"
      ],
      "dependencies": []
    },
    {
      "name": "application-example",
      "enabled": true,
      "repo": "https://github.com/example/application-example.git",
      "branch": "main",
      "architecture": "amd64",
      "apt_packages": [],
      "build_command": "releng-build-package",
      "dependencies": [
        {
          "project": "library-example",
          "packages": [
            "library-example",
            "library-example-dev"
          ]
        }
      ]
    }
  ]
}
```

### `name`

Project identifier. The same value is used for patches, project scripts, build output and CI artifacts.

```text
patches/<name>/
project-scripts/before/<name>
project-scripts/after/<name>
dist/<name>/
```

### `enabled`

Controls whether the project is selected when no project list is supplied.

```json
"enabled": true
```

A disabled project is still selected when an enabled or explicitly requested project depends on it.

### `repo`

Git repository to clone.

```json
"repo": "https://github.com/example/project.git"
```

### `branch`

Branch to clone.

```json
"branch": "main"
```

### `architecture`

Selects the default runner and build image from `defaults.runners` and `defaults.images`.

```json
"architecture": "arm64"
```

If omitted, `defaults.architecture` is used.

Supported architecture values are:

```text
arm64
amd64
```

### `image`

Optional per-project build image override.

```json
"image": "quay.io/droidian/build-essential:next-arm64"
```

If omitted, the image is selected from `defaults.images` using the project architecture.

### `runner`

Optional per-project GitHub Actions runner override.

```json
"runner": "ubuntu-24.04-arm"
```

If omitted, the runner is selected from `defaults.runners` using the project architecture.

### `apt_packages`

Additional packages installed before the project is built.

```json
"apt_packages": [
  "android-headers-30",
  "python3"
]
```

Packages in `defaults.apt_packages` are installed for every project.

### `build_command`

Command executed from the cloned project source directory.

```json
"build_command": "releng-build-package"
```

If omitted, `defaults.build_command` is used.

Shell commands may be used when a project needs a custom build invocation.

```json
"build_command": "export EXAMPLE=1; debuild --no-sign"
```

### `dependencies`

Declares packages that must be built before the project.

```json
"dependencies": [
  {
    "project": "library-example",
    "packages": [
      "library-example",
      "library-example-dev"
    ]
  }
]
```

The listed binary package names are installed from the dependency project's build output before the current project is built.

Use an empty `packages` array to install every `.deb` produced by that dependency:

```json
"dependencies": [
  {
    "project": "library-example",
    "packages": []
  }
]
```

## Project scripts

Optional project-specific scripts are stored as:

```text
project-scripts/before/<project-name>
project-scripts/after/<project-name>
```

`before/<project-name>` runs after APT packages and dependency packages are installed and before `build_command`.

`after/<project-name>` runs after `build_command` and before build artifacts are copied to `dist/<project-name>/`.

Scripts are executed with Bash from the cloned project source directory.

Available variables:

```text
PROJECT_NAME
PROJECT_REPO
PROJECT_BRANCH
PROJECT_SOURCE_DIR
PROJECT_BUILD_DIR
PROJECT_OUTPUT_DIR
DEB_BUILD_OPTIONS
DEBFULLNAME
DEBEMAIL
```

A project does not need either script.

## Patches

Project patches are stored under:

```text
patches/<project-name>/
```

Active patch names must use a four-digit numeric prefix:

```text
0001-first-change.patch
0002-second-change.patch
```

Patches are applied in numeric order.

To keep a patch in the repository without applying it, rename it to:

```text
0003-example.patch.disabled
```

A project does not need patches.

## Building

Build all enabled projects when their dependency closure uses one build architecture:

```bash
./scripts/build.sh
```

Build one project and its dependencies:

```bash
./scripts/build.sh application-example
```

Build multiple projects that use the same build architecture:

```bash
./scripts/build.sh library-example application-example
```

Local builds must run in an environment matching the configured architecture of the selected projects. If the selection contains multiple build architectures, build each architecture group separately.

Build output is written to:

```text
dist/<project-name>/
```

## GitHub Actions

Manual workflow runs accept a comma-separated `projects` input. An empty value selects all enabled projects.

Examples:

```text
application-example
```

```text
library-example,application-example
```

Dependencies are selected automatically and resolved before projects that require them are built.

Each successful project produces an intermediate artifact named:

```text
project-<project-name>
```

The final bundle is published as:

```text
droidian-packages-arm64.zip
```

Projects connected by dependencies are included in the final bundle only when the entire connected build component succeeds. Independent successful components are still included when another component fails.

The build workflow also produces `apt-repo-input`, which contains the `.deb` files and repository metadata consumed by the repository publishing workflow.


