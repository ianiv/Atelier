# Engine patches

`Scripts/apply-patches.sh` applies `Patches/<package>/*.patch` to the package checkouts in
`build/SourcePackages` before every `Scripts/build.sh` and `Scripts/release.sh` build. Builds from
the Xcode IDE use their own package checkouts and don't get them.

When the pinned revision changes, run `Scripts/apply-patches.sh`; a patch that no longer applies
has to be updated (or dropped once upstream has the change).
