# Demo recordings

The README's recordings, as [VHS](https://github.com/charmbracelet/vhs)
tapes. All but `release.tape` are real rk runs in a throwaway repository
that [`setup.sh`](setup.sh) makes, and push or publish nothing; `use.tape`
also keeps its launchers in a throwaway `XDG_DATA_HOME`. `release.tape` is
a real release.

The tapes run the `rk` on your PATH; to record this checkout, install it
first: `dart install "rk@{path: '$PWD'}"`.

| Tape | Records | From the repository root |
|---|---|---|
| `init.tape` | `rk init` choosing release-kit's own outputs | `vhs tool/demo/init.tape` |
| `plan.tape` | `rk plan` for the README's two packages | `vhs tool/demo/plan.tape` |
| `stage.tape` | Fleury's four packages staged, interrupted, resumed and reused | `FLEURY=../fleury vhs tool/demo/stage.tape` |
| `use.tape` | `rk use` switching between this checkout and a release | `vhs tool/demo/use.tape` |
| `release.tape` | `rk status` and `rk release` publishing for real | `RELEASE_REPO=<checkout> vhs tool/demo/release.tape` |

`release.tape` records an MP4, in real time, and the README's GIF is made
from it:

```sh
ffmpeg -i tool/demo/release.mp4 -vf "fps=12,tpad=stop_mode=clone:stop_duration=4,scale=860:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=full[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" -loop 0 tool/demo/release.gif
```

Record it only for a release you mean to make, after `rk stage` has
finished.

Re-record a tape when rk's output changes, so the README keeps showing
what rk really prints. `tool/` is not published to pub.dev.
