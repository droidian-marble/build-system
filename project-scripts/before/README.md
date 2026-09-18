# Before-build scripts

Place an optional script at:

```text
project-scripts/before/<project-name>
```

It runs after APT packages and dependency packages are installed and before the project's `build_command`.

The working directory is the cloned project source directory.
