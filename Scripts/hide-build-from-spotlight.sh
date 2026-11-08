# Sourced by the build scripts from the project root. Spotlight skips folders named *.noindex, so
# the outputs live in build.noindex and build is a symlink to it. Every build/ path keeps working.

if [ ! -L build ]; then
  if [ -d build ]; then
    for pid in $(pgrep xcodebuild || true); do
      if [ "$(lsof -a -p "$pid" -d cwd -Fn | sed -n 's/^n//p')" = "$PWD" ]; then
        echo "error: a build is running in $PWD; run this again when it finishes" >&2
        exit 1
      fi
    done
    mv build build.noindex
  else
    mkdir -p build.noindex
  fi
  ln -s build.noindex build
fi
