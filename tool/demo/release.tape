# rk releasing itself. This publishes for real: record it only for a release
# you mean to make, after `rk stage` has finished.
# From the repository root: RELEASE_REPO=<checkout to release> vhs tool/demo/release.tape
Output tool/demo/release.mp4
Source tool/demo/common.tape
Set Height 900
Set WaitTimeout 20m

Hide
Type `export PS1='$ ' PROMPT_COMMAND= && cd "${RELEASE_REPO:-.}" && clear`
Enter
Wait
Show

Type "rk status"
Sleep 400ms
Enter
Wait
Sleep 3s
Type "rk release"
Sleep 400ms
Enter
Wait+Screen@10m /\[y\/N\]/
Sleep 3s
Type "y"
Sleep 400ms
Enter
Wait
Sleep 6s
