# Droidian Patch Builder

Build system for compiling Droidian packages in a native ARM64 environment with local patches.

## projects.json

Projects to be built are defined in `projects.json`.

Example:

```json
{
  "projects": [
    {
      "name": "library-example",
      "enabled": false,
      "repo": "https://github.com/example/library-example.git",
      "branch": "main",
      "apt_packages": [
        "example-build-dependency"
      ]
    },
    {
      "name": "application-example",
      "enabled": true,
      "repo": "https://github.com/example/application-example.git",
      "branch": "development",
      "apt_packages": [
        "example-build-dependency",
        "python3"
      ],
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

### name

The project name used by the build system.

The same name is also used for the patch directory:

```text
patches/<name>/
```

### enabled

Controls whether the project is selected during a normal full build.

```json
"enabled": true
```

The project is built when running:

```bash
./scripts/build.sh
```

```json
"enabled": false
```

The project is not selected during a normal full build.

A disabled project is still built if another selected project depends on it.

For example, `library-example` may be disabled while `application-example` is enabled. If `application-example` depends on `library-example`, the library is built first and the application is built afterward.

A disabled project can also be built manually:

```bash
./scripts/build.sh library-example
```

### repo

The source Git repository:

```json
"repo": "https://github.com/example/application-example.git"
```

### branch

The Git branch to build:

```json
"branch": "development"
```

### apt_packages

Additional packages that must be installed inside the build container before building the project:

```json
"apt_packages": [
  "example-build-dependency",
  "python3"
]
```

If no additional packages are required:

```json
"apt_packages": []
```

### dependencies

If a project requires build output from another project, add it to `dependencies`.

For example, if `library-example` must be built before `application-example`:

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

Then:

```bash
./scripts/build.sh application-example
```

builds in this order:

```text
library-example
application-example
```

`packages` contains Debian binary package names that should be installed from the dependency output.

To install every compatible `.deb` produced by the dependency:

```json
"dependencies": [
  {
    "project": "library-example",
    "packages": []
  }
]
```

Multiple dependencies can be added:

```json
"dependencies": [
  {
    "project": "library-one",
    "packages": []
  },
  {
    "project": "library-two",
    "packages": [
      "library-two-dev"
    ]
  }
]
```

### before_build

If required, an additional command can be executed inside the container immediately before the project build:

```json
"before_build": "./some-script.sh"
```

If it is not required:

```json
"before_build": ""
```

## Patches

Patch files are stored by project name:

```text
patches/
├── library-example/
│   ├── 0001-first.patch
│   └── 0002-second.patch
└── application-example/
    ├── 0001-first.patch
    └── 0002-second.patch
```

Patches are applied in numeric order.

To disable a patch without deleting it, rename it to:

```text
0003-test.patch.disabled
```

## Build

To build all enabled projects:

```bash
./scripts/build.sh
```

To build a single project:

```bash
./scripts/build.sh application-example
```

To select multiple projects:

```bash
./scripts/build.sh library-example application-example
```

If a project has dependencies, they do not need to be listed separately:

```bash
./scripts/build.sh application-example
```

is enough.

Build output is stored under:

```text
dist/<project>/
```

Example:

```text
dist/
├── library-example/
└── application-example/
```

Local builds must be run on a native ARM64 machine.
