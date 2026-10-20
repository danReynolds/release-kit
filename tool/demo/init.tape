# rk init choosing release-kit's own outputs: Homebrew brings what it needs.
# From the repository root: vhs tool/demo/init.tape
Output tool/demo/init.gif
Source tool/demo/common.tape
Set Height 440

Hide
Type `export PS1='$ ' PROMPT_COMMAND= && cd "$(tool/demo/setup.sh init)" && clear`
Enter
Wait
Show

Type "rk init"
Sleep 400ms
Enter
Sleep 2500ms
Down
Sleep 700ms
Right
Sleep 350ms
Right
Sleep 350ms
Right
Sleep 350ms
Right
Sleep 900ms
Space
Sleep 2500ms
Down
Sleep 900ms
Enter
Sleep 2500ms
Right
Sleep 900ms
Enter
Wait
Sleep 1500ms
Type "cat release.toml"
Sleep 400ms
Enter
Wait
Sleep 5s
