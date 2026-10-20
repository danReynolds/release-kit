# Demo recordings

The README's recordings, as [VHS](https://github.com/charmbracelet/vhs)
tapes. Each is a real rk run in a throwaway repository that
[`setup.sh`](setup.sh) makes; nothing they record is pushed or published,
except `release.tape`, which is a real release.

| Tape | Records | From the repository root |
|---|---|---|
| `init.tape` | `rk init` choosing release-kit's own outputs | `vhs tool/demo/init.tape` |
| `stage.tape` | Fleury's four packages staged, then reused | `FLEURY=../fleury vhs tool/demo/stage.tape` |
| `recover.tape` | a stage interrupted, then finished by running it again | `FLEURY=../fleury vhs tool/demo/recover.tape` |
| `release.tape` | `rk status` and `rk release` publishing for real | `RELEASE_REPO=<checkout> vhs tool/demo/release.tape` |

`release.tape` records an MP4, in real time, and the README's GIF is made
from it:

```sh
ffmpeg -i tool/demo/release.mp4 -vf "fps=12,split[a][b];[a]palettegen=max_colors=128:stats_mode=full[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" -loop 0 tool/demo/release.gif
```

Record it only for a release you mean to make, after `rk stage` has
finished.

Re-record a tape when rk's output changes, so the README keeps showing
what rk really prints. `tool/` is not published to pub.dev.
