# After-build scripts

Place an optional script at:

```text
project-scripts/after/<project-name>
```

It runs after the project's `build_command` and before artifacts are copied to `dist/<project-name>/`.

The working directory is the cloned project source directory.
